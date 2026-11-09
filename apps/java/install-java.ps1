<#
.SYNOPSIS
Installs one Eclipse Temurin JDK release from Adoptium, puts it on the machine PATH and
sets JAVA_HOME.

.PARAMETER Version
JDK release, e.g. 21.0.4 (default: the newest release built for this machine).
#>
[CmdletBinding()]
param(
	[string]$Version = ''
)

$ErrorActionPreference = 'Stop'
# Progress rendering slows downloads and archive expansion many times over.
$ProgressPreference = 'SilentlyContinue'

if (-not $env:ProgramFiles) {
	throw 'java install: ProgramFiles is required'
}

$architecture = switch ($env:PROCESSOR_ARCHITECTURE) {
	'AMD64' { 'x64' }
	'ARM64' { 'aarch64' }
	default { throw "java install: unsupported architecture $env:PROCESSOR_ARCHITECTURE" }
}

$api = 'https://api.adoptium.net/v3'
$selector = "os=windows&architecture=$architecture&image_type=jdk&jvm_impl=hotspot" +
	'&heap_size=normal&vendor=eclipse&project=jdk'

if (-not $Version) {
	# The newest release with a build for this machine, as major.minor.security.
	$latest = Invoke-RestMethod -UseBasicParsing -Uri (
		"$api/info/release_versions?release_type=ga&$selector" +
		'&page_size=1&sort_method=DEFAULT&sort_order=DESC'
	)
	$semver = @($latest.versions)[0].semver
	if ($semver -notmatch '^(\d+\.\d+\.\d+)') {
		throw "java install: could not determine the newest release for windows/$architecture"
	}
	$Version = $Matches[1]
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
	throw "java install: invalid version: $Version"
}

# -Version is the release; [X,X.1) resolves its newest build for this machine.
# Adoptium answers 404 when it has no build of that release for this platform.
$range = [uri]::EscapeDataString("[$Version,$Version.1)")
try {
	$names = Invoke-RestMethod -UseBasicParsing -Uri (
		"$api/info/release_names?release_type=ga&version=$range&$selector" +
		'&page_size=1&sort_method=DEFAULT&sort_order=DESC'
	)
} catch {
	$status = $_.Exception.Response.StatusCode.value__
	if ($status -ne 404) {
		throw
	}
	$names = $null
}
$release = @($names.releases) | Select-Object -First 1
if (-not $release) {
	throw "java install: Adoptium publishes no build of $Version for windows/$architecture"
}
# java -version reports the release's own version: 27 for jdk-27+35,
# 27.0.1.0.2 for jdk-27.0.1.0.2+1, and 1.8.0_<security> for Java 8.
if ($release -match '^jdk8u(\d+)-b\d+$') {
	$expectedVersion = "1.8.0_$($Matches[1])"
} elseif ($release -match '^jdk-(\d+(\.\d+)*)\+') {
	$expectedVersion = $Matches[1]
} else {
	throw "java install: unexpected release name from Adoptium: $release"
}

$binaryUrl = "$api/binary/version/$release/windows/$architecture/jdk/hotspot/normal/eclipse?project=jdk"
$checksumUrl = "$api/checksum/version/$release/windows/$architecture/jdk/hotspot/normal/eclipse?project=jdk"
$root = Join-Path $env:ProgramFiles 'java'
$prefix = Join-Path $root $Version
$current = Join-Path $root 'current'
$pathEntry = Join-Path $current 'bin'
$work = Join-Path ([System.IO.Path]::GetTempPath()) "java-$([guid]::NewGuid())"

try {
	New-Item -ItemType Directory -Path $work -Force | Out-Null
	$archive = Join-Path $work 'jdk.zip'
	Invoke-WebRequest -UseBasicParsing -Uri $binaryUrl -OutFile $archive
	# Saved to a file: Windows PowerShell returns this response's content as bytes.
	$checksumFile = Join-Path $work 'jdk.zip.sha256.txt'
	Invoke-WebRequest -UseBasicParsing -Uri $checksumUrl -OutFile $checksumFile
	$checksumText = [System.IO.File]::ReadAllText($checksumFile).Trim()
	$expected = (($checksumText -split '\s+')[0]).ToLowerInvariant()
	if ($expected -notmatch '^[0-9a-f]{64}$') {
		throw "java install: Adoptium did not publish a checksum for $release"
	}
	$actual = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant()
	if ($actual -ne $expected) {
		throw "java install: checksum verification failed for $release"
	}

	$unpacked = Join-Path $work 'unpacked'
	Expand-Archive -LiteralPath $archive -DestinationPath $unpacked
	$source = Get-ChildItem -LiteralPath $unpacked -Directory |
		Where-Object {
			Test-Path -LiteralPath (Join-Path $_.FullName 'bin\java.exe') -PathType Leaf
		} |
		Select-Object -First 1
	if (-not $source) {
		throw 'java install: java.exe is missing from the archive'
	}

	New-Item -ItemType Directory -Path $root -Force | Out-Null
	Remove-Item -LiteralPath $prefix -Recurse -Force -ErrorAction SilentlyContinue
	Move-Item -LiteralPath $source.FullName -Destination $prefix

	if (Test-Path -LiteralPath $current) {
		$item = Get-Item -LiteralPath $current -Force
		if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
			throw "java install: $current exists and is not a junction"
		}
		[IO.Directory]::Delete($current)
	}
	New-Item -ItemType Junction -Path $current -Target $prefix | Out-Null

	$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
	$entries = @($machinePath -split ';' | Where-Object { $_ })
	if ($pathEntry -notin $entries) {
		[Environment]::SetEnvironmentVariable(
			'Path',
			(@($entries) + $pathEntry) -join ';',
			'Machine'
		)
	}
	[Environment]::SetEnvironmentVariable('JAVA_HOME', $current, 'Machine')

	$previousPreference = $ErrorActionPreference
	try {
		$ErrorActionPreference = 'Continue'
		$versionOutput = (& (Join-Path $pathEntry 'java.exe') -version 2>&1 | Out-String)
		$versionExitCode = $LASTEXITCODE
	} finally {
		$ErrorActionPreference = $previousPreference
	}
	if ($versionExitCode -ne 0 -or
		$versionOutput -notmatch "`"$([regex]::Escape($expectedVersion))`"") {
		throw "java install: installed version does not match $Version`: $versionOutput"
	}
	Write-Host $versionOutput.Trim()
} finally {
	Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
