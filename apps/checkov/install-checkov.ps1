$ErrorActionPreference = 'Stop'

# Installs one Checkov release under Program Files and exposes it through a `current`
# junction plus a single machine PATH entry — the shape go, java, node, trivy, syft,
# cosign and snyk use on Windows, so switching versions never rewrites the PATH.
#
# Two things differ from the rest of the catalog:
#
#   - The project publishes no checksums file. GitHub reports a SHA-256 of its own for
#     each release asset, and that is what is verified against. It guards a truncated or
#     tampered download, not a compromised release.
#
#   - The archive spells the binary "dist//checkov.exe", with a doubled separator. The
#     entry is therefore taken by its file name rather than extracted by path, which also
#     avoids Expand-Archive entirely.

function Fail($message) { throw "checkov install: $message" }
function Note($message) { Write-Host "checkov install: $message" }

if (-not $env:ProgramFiles) { Fail 'ProgramFiles is required' }
if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64' -and $env:PROCESSOR_ARCHITEW6432 -ne 'AMD64') {
	Fail "unsupported architecture $env:PROCESSOR_ARCHITECTURE; the project builds x86_64 only"
}

# Windows PowerShell 5.1 leaves TLS at the machine default, which on older images can
# still be 1.0; GitHub requires 1.2.
[Net.ServicePointManager]::SecurityProtocol =
	[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$api = 'https://api.github.com/repos/bridgecrewio/checkov/releases'
$headers = @{ 'User-Agent' = 'orc-checkov' }

$version = $env:APP_VERSION -replace '^v', ''
if ($version -and $version -notmatch '^\d+\.\d+\.\d+\z') { Fail "invalid version: $version" }

$asset = 'checkov_windows_X86_64.zip'

$root = Join-Path $env:ProgramFiles 'checkov'
$current = Join-Path $root 'current'
$work = Join-Path ([IO.Path]::GetTempPath()) "checkov-$([guid]::NewGuid())"
# Known already when a version was requested; filled in after discovery otherwise.
$prefix = if ($version) { Join-Path $root $version } else { $null }

# Runs the binary and returns what it reports, or $null. Both spellings are tried. The
# preference is lowered because `2>&1` on a native command is a terminating error while
# it is Stop.
function Get-Reported($exe) {
	if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { return $null }
	$previous = $ErrorActionPreference
	$ErrorActionPreference = 'Continue'
	try {
		foreach ($argument in @('--version', 'version')) {
			$out = (& $exe $argument 2>&1 | Out-String -Width 4096).Trim()
			if ($LASTEXITCODE -eq 0) { return $out }
		}
		return $null
	} finally {
		$ErrorActionPreference = $previous
	}
}

# The junction is what the PATH entry points at, so the PATH is written once and never
# again. Anything else already sitting at that name is not ours to replace.
function Set-Exposure {
	if (Test-Path -LiteralPath $current) {
		$item = Get-Item -LiteralPath $current -Force
		if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
			Fail "$current exists and is not a junction"
		}
		$target = [IO.Path]::GetFullPath([string] $item.Target).TrimEnd('\')
		if ($target -eq [IO.Path]::GetFullPath($prefix).TrimEnd('\')) { return }
		[IO.Directory]::Delete($current)
	}
	New-Item -ItemType Junction -Path $current -Target $prefix | Out-Null

	$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
	$entries = @($machinePath -split ';' | Where-Object { $_ })
	if ($current -notin $entries) {
		[Environment]::SetEnvironmentVariable('Path', (@($entries) + $current) -join ';', 'Machine')
	}
}

# Already here? The pool image is baked straight after this phase and the node is then
# rebuilt from that image, which runs this phase again on a disk that already carries the
# binary.
function Test-Installed {
	if (-not $prefix) { return $false }
	$reported = Get-Reported (Join-Path $prefix 'checkov.exe')
	return [bool] ($reported -and $reported -match [regex]::Escape($version))
}

# A requested version can be answered from the node's own disk without touching the
# network at all. That matters here more than elsewhere: this app's checksum lives in the
# GitHub API rather than in a published file, so every install that gets as far as the API
# spends one of the sixty unauthenticated requests an hour GitHub allows per address — and
# a pool can hold more nodes than that behind one address.
if ($version -and (Test-Installed)) {
	Set-Exposure
	Note "checkov $version is already installed"
	exit 0
}

try {
	if ($version) {
		$release = Invoke-RestMethod -UseBasicParsing -Headers $headers -Uri "$api/tags/$version"
	} else {
		# APP_VERSION arrives unset when the request resolved to the implicit `default`
		# tag. The newest version has to be asked for before the disk can be checked,
		# because until then there is no version to look for.
		Note 'no version was requested; taking the newest release'
		$release = Invoke-RestMethod -UseBasicParsing -Headers $headers -Uri "$api/latest"
	}
} catch {
	Fail "could not read the release from GitHub: $($_.Exception.Message)"
}

if (-not $version) {
	$version = ([string] $release.tag_name) -replace '^v', ''
	if ($version -notmatch '^\d+\.\d+\.\d+\z') { Fail 'the release response names no usable version' }
	Note "newest release is $version"
	$prefix = Join-Path $root $version
	if (Test-Installed) {
		Set-Exposure
		Note "checkov $version is already installed"
		exit 0
	}
}

$base = "https://github.com/bridgecrewio/checkov/releases/download/$version"

$assetInfo = @($release.assets | Where-Object { $_.name -eq $asset })[0]
if (-not $assetInfo) { Fail "release $version publishes no $asset" }
$expected = (([string] $assetInfo.digest) -replace '^sha256:', '').ToLowerInvariant()
if ($expected -notmatch '^[0-9a-f]{64}\z') {
	Fail "GitHub published no usable SHA-256 for $asset in release $version"
}

try {
	New-Item -ItemType Directory -Path $work -Force | Out-Null
	$downloaded = Join-Path $work $asset

	Note "downloading $asset"
	Invoke-WebRequest -UseBasicParsing -Uri "$base/$asset" -OutFile $downloaded

	$actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $downloaded).Hash.ToLowerInvariant()
	if ($actual -ne $expected) { Fail "checksum verification failed for $asset" }

	New-Item -ItemType Directory -Path $root -Force | Out-Null
	Remove-Item -LiteralPath $prefix -Recurse -Force -ErrorAction SilentlyContinue
	New-Item -ItemType Directory -Path $prefix -Force | Out-Null

	# Taken by file name, not by path: the archive spells the entry "dist//checkov.exe".
	Add-Type -AssemblyName System.IO.Compression.FileSystem
	$archive = [IO.Compression.ZipFile]::OpenRead($downloaded)
	try {
		$entry = @($archive.Entries | Where-Object { $_.Name -eq 'checkov.exe' })[0]
		if (-not $entry) { Fail 'the archive holds no file named checkov.exe' }
		[IO.Compression.ZipFileExtensions]::ExtractToFile(
			$entry, (Join-Path $prefix 'checkov.exe'), $true)
	} finally {
		$archive.Dispose()
	}

	Set-Exposure

	# This process started before the PATH was written, so the binary is run by absolute
	# path.
	$reported = Get-Reported (Join-Path $prefix 'checkov.exe')
	if (-not $reported) { Fail 'checkov does not run on this node' }
	if ($reported -notmatch [regex]::Escape($version)) {
		Fail "installed version '$reported' does not match $version"
	}
} finally {
	Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Note "checkov $version installed at $prefix"
