$ErrorActionPreference = 'Stop'

# Installs one .NET SDK version into a root shared by every installed version.
# See install-dotnet.sh for why the layout differs from go, java and node: the
# archive is versioned inside, and Microsoft documents extracting several
# versions into the same folder.
#
# There is no `current` junction here, and none is needed. Those exist so one
# version of a per-version tree can be exposed; this root exposes all of them at
# once, which is the point.

# APP_VERSION is unset when the assignment resolved to the implicit `default`
# tag — which is the entry the version list offers first, so it is the ordinary
# case and not an error. The newest offered SDK is then resolved below, from the
# same index the list itself is built from.
$version = $env:APP_VERSION
if ($version -and $version -notmatch '^\d+\.\d+\.\d+$') {
	throw "dotnet install: invalid APP_VERSION: $version"
}

$architecture = switch ($env:PROCESSOR_ARCHITECTURE) {
	'AMD64' { 'x64' }
	'ARM64' { 'arm64' }
	default { throw "dotnet install: unsupported architecture $env:PROCESSOR_ARCHITECTURE" }
}

$feed = if ($env:DOTNET_FEED) { $env:DOTNET_FEED } else { 'https://builds.dotnet.microsoft.com/dotnet' }
$metadata = if ($env:DOTNET_METADATA) { $env:DOTNET_METADATA } else { "$feed/release-metadata" }
if ($env:DOTNET_INSTALL_ROOT) {
	$root = $env:DOTNET_INSTALL_ROOT
} else {
	if (-not $env:ProgramFiles) {
		throw 'dotnet install: ProgramFiles is required'
	}
	$root = Join-Path $env:ProgramFiles 'dotnet'
}
# Records what this app changed, so uninstall puts back exactly that, and which
# versions it installed, so uninstall can find them when no version is named. On
# Windows the default root is also where a Microsoft installer would have put
# .NET, so this matters more than on Linux.
$marker = Join-Path $root '.orc-dotnet-install'
$work = Join-Path ([System.IO.Path]::GetTempPath()) "dotnet-$([guid]::NewGuid())"

function Get-MarkerLines {
	if (Test-Path -LiteralPath $marker -PathType Leaf) {
		return @(Get-Content -LiteralPath $marker)
	}
	return @()
}

function Get-MarkerFlag([string] $name) {
	return [bool](@(Get-MarkerLines) -match "^$name=1$")
}

function Write-Marker([bool] $rootCreated, [bool] $pathAdded) {
	# The sdk= lines are this app's record of what it installed, kept across a
	# rewrite of the flags above them.
	$kept = @(Get-MarkerLines | Where-Object { $_ -like 'sdk=*' })
	if (-not $rootCreated -and -not $pathAdded -and $kept.Count -eq 0) { return }
	$flags = @(
		"root-created=$(if ($rootCreated) { 1 } else { 0 })",
		"path-added=$(if ($pathAdded) { 1 } else { 0 })"
	)
	($flags + $kept) | Set-Content -LiteralPath $marker -Encoding ASCII
}

try {
	New-Item -ItemType Directory -Path $work -Force | Out-Null

	# Which band publishes this version is asked, not guessed: 2.1.202 is
	# published under band 2.0, so deriving it from the number is wrong. The
	# index is the same document the version list is built from — and when no
	# version was requested at all, it is where the newest one comes from.
	$channel = $null
	$index = $null
	try {
		$index = Invoke-RestMethod -UseBasicParsing -Uri "$metadata/releases-index.json"
	} catch {
		$index = $null
	}

	if (-not $version) {
		if (-not $index) {
			throw 'dotnet install: no version was requested and the release index could not be read'
		}
		# Narrowed the same way artifact.yaml narrows the offered list: plain
		# three-part versions, .NET 5 and later. The band comes from the same
		# entry, so it never has to be derived.
		$entry = @($index.'releases-index') |
			Where-Object {
				$_.'latest-sdk' -match '^\d+\.\d+\.\d+$' -and
				[int](($_.'latest-sdk' -split '\.')[0]) -ge 5
			} |
			Sort-Object { [version] $_.'latest-sdk' } |
			Select-Object -Last 1
		if (-not $entry) {
			throw 'dotnet install: the release index offers no installable SDK version'
		}
		$version = $entry.'latest-sdk'
		$channel = $entry.'channel-version'
		Write-Host "dotnet install: newest offered SDK is $version, from band $channel"
	} elseif ($index) {
		$entry = @($index.'releases-index') |
			Where-Object { $_.'latest-sdk' -eq $version } |
			Select-Object -First 1
		if ($entry) { $channel = $entry.'channel-version' }
	}
	if (-not $channel) {
		# A version installed by hand need not be any band's newest, and then
		# the index cannot name it.
		$channel = ($version -split '\.')[0, 1] -join '.'
	}

	$asset = "dotnet-sdk-$version-win-$architecture.zip"

	# Invoke-RestMethod parses the metadata into objects, so the Windows half
	# does not need the token scanning its Linux counterpart does.
	$releases = Invoke-RestMethod -UseBasicParsing -Uri "$metadata/$channel/releases.json"

	$sdk = $null
	foreach ($release in @($releases.releases)) {
		foreach ($candidate in @($release.sdks) + @($release.sdk)) {
			if ($candidate -and $candidate.version -eq $version) {
				$sdk = $candidate
				break
			}
		}
		if ($sdk) { break }
	}
	if (-not $sdk) {
		throw "dotnet install: band $channel publishes no SDK $version"
	}

	# Matched on the URL, not on `name`: the metadata's name field carries no
	# version at all (it is "dotnet-sdk-win-x64.zip"), so matching it against the
	# versioned filename would never hit and would silently fall through.
	$file = @($sdk.files) | Where-Object { $_.url -like "*/$asset" } | Select-Object -First 1
	if (-not $file -or -not $file.hash) {
		throw "dotnet install: band $channel publishes no $asset"
	}
	if ($file.hash -notmatch '^[0-9a-fA-F]{128}$') {
		throw "dotnet install: the published checksum for $asset is not a SHA-512"
	}

	$archive = Join-Path $work $asset
	Invoke-WebRequest -UseBasicParsing -Uri $file.url -OutFile $archive
	$actual = (Get-FileHash -Algorithm SHA512 $archive).Hash.ToLowerInvariant()
	if ($actual -ne $file.hash.ToLowerInvariant()) {
		throw "dotnet install: checksum verification failed for $asset"
	}

	# Ownership is decided and recorded before anything can go wrong, so an
	# install that fails halfway is still removable. A second version installed
	# later must not downgrade what an earlier one recorded.
	$rootCreated = Get-MarkerFlag 'root-created'
	$pathAdded = Get-MarkerFlag 'path-added'
	if (-not (Test-Path -LiteralPath $root -PathType Container)) {
		$rootCreated = $true
	}

	New-Item -ItemType Directory -Path $root -Force | Out-Null
	Write-Marker $rootCreated $pathAdded

	# -Force so the files an earlier version left are overwritten rather than
	# treated as a collision. Merging into the root is the intended behaviour.
	Expand-Archive -LiteralPath $archive -DestinationPath $root -Force

	$muxer = Join-Path $root 'dotnet.exe'
	if (-not (Test-Path -LiteralPath $muxer -PathType Leaf)) {
		throw "dotnet install: $asset left no dotnet.exe in $root"
	}
	if (-not (Test-Path -LiteralPath (Join-Path $root "sdk\$version") -PathType Container)) {
		throw "dotnet install: $asset left no sdk\$version in $root"
	}

	# One machine PATH entry for the root itself. The muxer finds everything
	# beside itself, so nothing else needs to be exposed. Compared with the
	# trailing separator stripped, the same way uninstall compares, so a node
	# that already lists the root does not collect a second copy.
	$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
	$entries = @($machinePath -split ';' | Where-Object { $_ })
	$normalized = @($entries | ForEach-Object { $_.TrimEnd('\') })
	if ($root.TrimEnd('\') -notin $normalized) {
		[Environment]::SetEnvironmentVariable(
			'Path',
			(@($entries) + $root) -join ';',
			'Machine'
		)
		$pathAdded = $true
	}
	Write-Marker $rootCreated $pathAdded

	# Telemetry is off for this one check; it stays on for the node's own builds,
	# which is the node's decision. The README names the variable. Set on this
	# process only — it ends with the phase and nothing persists.
	$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
	$env:DOTNET_NOLOGO = '1'

	# `2>&1` while $ErrorActionPreference is 'Stop' turns anything the SDK writes
	# to stderr into a terminating error, which would kill the phase on a node
	# where the SDK merely warns. Lowered for this call alone — the same guard
	# java/install-java.ps1 puts around its own version check. -Width so a long
	# root cannot wrap a line and hide the version from the check below.
	$listed = ''
	$listedExitCode = 1
	$previousPreference = $ErrorActionPreference
	try {
		$ErrorActionPreference = 'Continue'
		$listed = (& $muxer --list-sdks 2>&1 | Out-String -Width 4096)
		$listedExitCode = $LASTEXITCODE
	} finally {
		$ErrorActionPreference = $previousPreference
	}
	if ($listedExitCode -ne 0) {
		throw "dotnet install: the SDK does not run on this node: $listed"
	}

	$installed = @(
		$listed -split "`r?`n" |
			Where-Object { $_ } |
			ForEach-Object { ($_ -split ' ')[0] }
	)
	if ($version -notin $installed) {
		throw "dotnet install: sdk $version is not in the installed list: $listed"
	}

	# Recorded so uninstall can find it when the platform names no version
	# either — the same `default` case that may have brought us here.
	if (@(Get-MarkerLines) -notcontains "sdk=$version") {
		Add-Content -LiteralPath $marker -Value "sdk=$version" -Encoding ASCII
	}

	Write-Host "dotnet install: dotnet $version installed at $root; SDKs now present: $($installed -join ' ')"
} finally {
	Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
