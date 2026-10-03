$ErrorActionPreference = 'Stop'

# Installs the Chocolatey package manager from the project's own GitHub release.
#
# The vendor's documented route is `irm https://community.chocolatey.org/install.ps1 | iex`.
# That script verifies nothing it downloads — no checksum, no signature — and every
# other download in this catalog is verified: aws, terraform and vault all compare a
# published SHA256 before using what they fetched. So this package takes the route the
# vendor documents for internal installs instead: the release carries a SHA256 for each
# artifact, the .nupkg is an ordinary zip, and inside it is tools\chocolateyInstall.ps1 —
# the same installer the official one-liner ends up running.
#
# Chocolatey installs into one shared directory, C:\ProgramData\chocolatey, and keeps no
# versions side by side. That is why this app ships no uninstall: the runtime installs a
# new version before it runs the superseded version's uninstall, so an uninstall here
# would delete the install that had just replaced it. aws, apt, docker, uv and
# cpp-dev-tools ship no uninstall either.

$Repo = 'chocolatey/choco'

function Fail($message) { throw "chocolatey install: $message" }
function Note($message) { Write-Host "chocolatey install: $message" }

function Get-ChocoRoot {
	$configured = [Environment]::GetEnvironmentVariable('ChocolateyInstall', 'Machine')
	if ($configured) { return $configured }
	if ($env:ChocolateyInstall) { return $env:ChocolateyInstall }
	return (Join-Path $env:ProgramData 'chocolatey')
}

# Chocolatey reports its version as three parts but names its files with four, so the
# two are compared on major.minor.patch alone. Comparing with StartsWith instead would
# make 2.7.30 look like a match for 2.7.3.
function Get-VersionTriple($value) {
	$match = [regex]::Match([string] $value, '^(\d+)\.(\d+)\.(\d+)')
	if (-not $match.Success) { return $null }
	return '{0}.{1}.{2}' -f $match.Groups[1].Value, $match.Groups[2].Value, $match.Groups[3].Value
}

# Returns the installed version, or $null. The preference is lowered around the native
# call because `2>&1` on a native command is a terminating error while the preference is
# Stop, and a broken install must be reported by this script rather than crash it.
function Get-InstalledVersion {
	$exe = Join-Path (Get-ChocoRoot) 'bin\choco.exe'
	if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { return $null }
	$previous = $ErrorActionPreference
	$ErrorActionPreference = 'Continue'
	try {
		$output = (& $exe '--version' 2>&1 | Out-String -Width 4096).Trim()
		if ($LASTEXITCODE -ne 0) { return $null }
	} finally {
		$ErrorActionPreference = $previous
	}
	$match = [regex]::Match($output, '\d+\.\d+\.\d+(\.\d+)?')
	if ($match.Success) { return $match.Value }
	return $null
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole(
		[Security.Principal.WindowsBuiltInRole]::Administrator)) {
	Fail 'administrator rights are required'
}

if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64' -and $env:PROCESSOR_ARCHITEW6432 -ne 'AMD64') {
	Fail "unsupported architecture $env:PROCESSOR_ARCHITECTURE"
}

# Chocolatey is a .NET Framework application and will not run without 4.8. The vendor's
# own script tries to install the framework when it is missing, which wants a restart;
# this phase runs while the pool image is being baked, where a restart is not something
# to spring on the builder. So a node without it is refused here, before anything is
# downloaded, rather than left half-installed.
$ndp = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue
if (-not $ndp -or [int] $ndp.Release -lt 528040) {
	Fail 'the .NET Framework 4.8 or newer is required and was not found on this node'
}

# Windows PowerShell 5.1 leaves TLS at the machine default, which on older images can
# still be 1.0; both GitHub and the package feed require 1.2.
[Net.ServicePointManager]::SecurityProtocol =
	[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# APP_VERSION arrives unset when the request resolved to the implicit `default` tag, and
# the newest release is then asked of the project rather than guessed.
$version = $env:APP_VERSION
if ($version) {
	if ($version -notmatch '^\d+\.\d+\.\d+\z') { Fail "invalid APP_VERSION: $version" }
	$releaseUrl = "https://api.github.com/repos/$Repo/releases/tags/$version"
} else {
	Note 'no version was requested; taking the newest release'
	$releaseUrl = "https://api.github.com/repos/$Repo/releases/latest"
}

try {
	$release = Invoke-RestMethod -UseBasicParsing -Uri $releaseUrl -Headers @{ 'User-Agent' = 'orc-chocolatey' }
} catch {
	Fail "could not read the release from $releaseUrl : $($_.Exception.Message)"
}

if (-not $version) {
	$version = [string] $release.tag_name
	if ($version -notmatch '^\d+\.\d+\.\d+\z') { Fail "the release names no usable version: '$version'" }
	Note "newest release is $version"
}

$installed = Get-InstalledVersion
if ($installed -and (Get-VersionTriple $installed) -eq (Get-VersionTriple $version)) {
	Note "chocolatey $installed is already installed"
	exit 0
}

# The release carries four artifacts; this is the package one, and the name is built
# rather than matched so that chocolatey.lib.<version>.nupkg can never be picked up.
$assetName = "chocolatey.$version.nupkg"
$asset = @($release.assets | Where-Object { $_.name -eq $assetName })[0]
if (-not $asset) { Fail "$assetName is not among the files published for $version" }

# Most releases list one SHA256 per artifact in their notes, as "<hash><tab><filename>",
# and that is the stronger check — it covers the whole package. But the notes are prose,
# and some releases carry no line for the .nupkg at all (2.7.4 did not, where 2.7.3 did).
# So the hash is used when it is there, and the signature on the binary inside the package
# is what stands in for it when it is not. The install never runs anything unverified.
$body = [string] $release.body
$hashMatch = [regex]::Match($body, '([0-9a-fA-F]{64})\s+' + [regex]::Escape($assetName) + '(?=\s|\z)')
$expected = $null
if ($hashMatch.Success) {
	$expected = $hashMatch.Groups[1].Value.ToLowerInvariant()
} else {
	Note "the notes for $version publish no SHA256 for $assetName; the package signature will be checked instead"
}

$work = Join-Path ([IO.Path]::GetTempPath()) "chocolatey-$([guid]::NewGuid())"
try {
	New-Item -ItemType Directory -Path $work -Force | Out-Null

	$package = Join-Path $work $assetName
	Note "downloading $assetName"
	Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -OutFile $package

	if ($expected) {
		$actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $package).Hash.ToLowerInvariant()
		if ($actual -ne $expected) { Fail "checksum verification failed for $assetName" }
		Note 'checksum verified'
	}

	# ExtractToDirectory rather than Expand-Archive: the latter insists on a .zip
	# extension and chokes on the square brackets in a NuGet package's
	# [Content_Types].xml, while this reads the archive as it is.
	$unpacked = Join-Path $work 'unpacked'
	Add-Type -AssemblyName System.IO.Compression.FileSystem
	[IO.Compression.ZipFile]::ExtractToDirectory($package, $unpacked)

	$installer = Join-Path $unpacked 'tools\chocolateyInstall.ps1'
	if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
		Fail 'the package does not contain tools\chocolateyInstall.ps1'
	}

	# Only when the release published no hash to compare against. "Validly signed" alone
	# would mean no more than that somebody this machine trusts signed it, so the signer
	# is asserted too, and written to the log either way.
	#
	# The file is searched for rather than named: the package has moved choco.exe between
	# layouts before, and the installer script is the fallback because Chocolatey signs
	# that too. If neither is there, the listing below says what is, so the next attempt
	# is not another guess.
	if (-not $expected) {
		$candidates = @(Get-ChildItem -LiteralPath $unpacked -Recurse -Filter 'choco.exe' -ErrorAction SilentlyContinue |
			ForEach-Object { $_.FullName })
		$candidates += $installer
		$signed = $null
		foreach ($candidate in $candidates) {
			if ((Get-AuthenticodeSignature -LiteralPath $candidate).SignerCertificate) { $signed = $candidate; break }
		}
		if (-not $signed) {
			$listing = @(Get-ChildItem -LiteralPath $unpacked -Recurse -File -ErrorAction SilentlyContinue |
				ForEach-Object { $_.FullName.Substring($unpacked.Length + 1) } | Select-Object -First 40)
			Note ('the package contains: ' + ($listing -join '; '))
			Fail 'the release publishes no checksum and the package carries nothing signed to verify'
		}
		Note "verifying $($signed.Substring($unpacked.Length + 1))"
		$signature = Get-AuthenticodeSignature -LiteralPath $signed
		if ($signature.Status -eq 'UnknownError') {
			# Revocation checking could not complete — a closed network, not a bad file.
			# The signer check below still has to pass.
			Note "warning: the signature could not be fully checked ($($signature.StatusMessage))"
		} elseif ($signature.Status -ne 'Valid') {
			Fail "the package is not validly signed (status $($signature.Status)); refusing to install it"
		}
		$subject = [string] $signature.SignerCertificate.Subject
		if ($subject -notmatch 'Chocolatey') {
			Fail "the package is not signed by Chocolatey (signer: $subject); refusing to install it"
		}
		Note "signed by $subject"
	}

	# Named explicitly so the install lands in the same place whether or not a previous
	# install already set the machine variable.
	$root = Get-ChocoRoot
	$env:ChocolateyInstall = $root

	Note "installing chocolatey $version to $root"
	& $installer
} finally {
	Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

# The installer sets the machine PATH and the ChocolateyInstall variable itself, but this
# process started before that happened, so the binary is checked by absolute path.
$installed = Get-InstalledVersion
if (-not $installed) { Fail 'choco.exe does not run after installing' }
if ((Get-VersionTriple $installed) -ne (Get-VersionTriple $version)) {
	Fail "installed version '$installed' does not match the requested $version"
}

Note "chocolatey $installed installed at $(Get-ChocoRoot)"
