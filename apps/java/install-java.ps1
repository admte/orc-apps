<#
.SYNOPSIS
Installs one Eclipse Temurin JDK release from Adoptium, puts it on the machine PATH and
sets JAVA_HOME.

.PARAMETER Version
JDK release, e.g. 21.0.4. Defaults to the newest release Adoptium publishes.
#>
[CmdletBinding()]
param(
	[string]$Version = ''
)

$ErrorActionPreference = 'Stop'

# PowerShell 5.1 redraws the download progress bar on every block it reads,
# which on a one-core node costs more than the transfer itself.
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

if (-not $Version) {
	# The version arrives empty when the request resolved to the implicit
	# `default` tag. Adoptium reports semver as X.Y.Z+build, but some releases
	# carry more components, e.g. 27.0.1.0.2+1. Take the newest that is X.Y.Z
	# and nothing more: that is what artifact.yaml offers as a version, and
	# what the [X,X.1) range below resolves.
	try {
		$versions = Invoke-RestMethod -UseBasicParsing -Uri (
			"$api/info/release_versions?release_type=ga&vendor=eclipse" +
			"&os=windows&architecture=$architecture&image_type=jdk" +
			'&sort_method=DEFAULT&sort_order=DESC&page_size=50'
		)
	} catch {
		throw "java install: could not read the newest release from Adoptium: $($_.Exception.Message)"
	}
	$semver = [string] ((@($versions.versions) |
		Where-Object { $_.semver -match '^\d+\.\d+\.\d+\+' } |
		Select-Object -First 1).semver)
	if (-not $semver) {
		throw 'java install: the release list names no X.Y.Z version'
	}
	$Version = ($semver -split '\+')[0]
	Write-Host "java install: no version was requested; taking the newest release, $Version"
}

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
	throw "java install: invalid version: $Version"
}
$selector = "os=windows&architecture=$architecture&image_type=jdk&jvm_impl=hotspot" +
	'&heap_size=normal&vendor=eclipse&project=jdk'

# -Version is the release; [X,X.1) resolves its newest build for this machine.
$range = [uri]::EscapeDataString("[$Version,$Version.1)")
# Adoptium answers 404 when nothing matches, which is how "this platform has
# no such release" arrives; without this the cmdlet spills a stack trace.
try {
	$names = Invoke-RestMethod -UseBasicParsing -Uri (
		"$api/info/release_names?release_type=ga&version=$range&$selector" +
		'&page_size=1&sort_method=DEFAULT&sort_order=DESC'
	)
} catch {
	throw "java install: Adoptium publishes no $Version release for windows/$architecture"
}
$release = @($names.releases) | Select-Object -First 1
if (-not $release) {
	throw "java install: Adoptium publishes no $Version release for windows/$architecture"
}
if ($release -match '^jdk8u(\d+)-b\d+$') {
	# Java 8 reports 1.8.0_<security>.
	$expectedVersion = "1.8.0_$($Matches[1])"
} elseif ($release -match '^jdk-(\d+(?:\.\d+)*)\+') {
	# A request for 27.0.1 is answered with jdk-27.0.1.0.2+1, and that JDK
	# reports 27.0.1.0.2, so take the expected version from the release name
	# rather than from what was asked for.
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

function Set-Exposure {
	New-Item -ItemType Directory -Path $root -Force | Out-Null
	if (Test-Path -LiteralPath $current) {
		$item = Get-Item -LiteralPath $current -Force
		if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
			throw "java install: $current exists and is not a junction"
		}
		$target = [IO.Path]::GetFullPath([string] $item.Target).TrimEnd('\')
		if ($target -ne [IO.Path]::GetFullPath($prefix).TrimEnd('\')) {
			[IO.Directory]::Delete($current)
			New-Item -ItemType Junction -Path $current -Target $prefix | Out-Null
		}
	} else {
		New-Item -ItemType Junction -Path $current -Target $prefix | Out-Null
	}

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
}

function Get-Reported($exe) {
	if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { return $null }
	$previous = $ErrorActionPreference
	$ErrorActionPreference = 'Continue'
	try {
		# java writes its banner to stderr. Fold that into the output, and turn
		# each record into plain text: left as error records, Out-String draws
		# them as a NativeCommandError with a stack trace.
		$out = (& $exe -version 2>&1 | ForEach-Object { "$_" } | Out-String -Width 4096).Trim()
		if ($LASTEXITCODE -eq 0) { return $out }
		return $null
	} finally {
		$ErrorActionPreference = $previous
	}
}

# The pool image is baked straight after this phase, and every node is rebuilt
# from that image. Without this check each node downloads and unpacks a release
# the disk already carries.
$existing = Get-Reported (Join-Path $prefix 'bin\java.exe')
if ($existing -and $existing -match "`"$([regex]::Escape($expectedVersion))`"") {
	Set-Exposure
	Write-Host "java install: java $Version is already installed"
	exit 0
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) "java-$([guid]::NewGuid())"

try {
	New-Item -ItemType Directory -Path $work -Force | Out-Null
	$archive = Join-Path $work 'jdk.zip'
	Invoke-WebRequest -UseBasicParsing -Uri $binaryUrl -OutFile $archive
	# Invoke-WebRequest hands .Content back as a byte[] when the response is not
	# a text content type, which is what the Adoptium checksum endpoint returns,
	# so write it to a file and read the text from there.
	$checksumFile = Join-Path $work 'jdk.sha256'
	Invoke-WebRequest -UseBasicParsing -Uri $checksumUrl -OutFile $checksumFile
	$expected = (((Get-Content -LiteralPath $checksumFile -Raw).Trim() -split '\s+')[0]).ToLowerInvariant()
	if ($expected -notmatch '^[0-9a-f]{64}$') {
		throw "java install: Adoptium did not publish a checksum for $release"
	}
	$actual = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant()
	if ($actual -ne $expected) {
		throw "java install: checksum verification failed for $release"
	}

	$unpacked = Join-Path $work 'unpacked'
	New-Item -ItemType Directory -Path $unpacked -Force | Out-Null
	# tar.exe, not Expand-Archive: a JDK holds thousands of files, which the
	# cmdlet writes one at a time on PowerShell 5.1.
	$tar = Get-Command tar.exe -ErrorAction SilentlyContinue
	if ($tar) {
		& $tar.Source -xf $archive -C $unpacked
		if ($LASTEXITCODE -ne 0) { throw 'java install: could not unpack the archive' }
	} else {
		Expand-Archive -LiteralPath $archive -DestinationPath $unpacked
	}
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

	Set-Exposure

	$previousPreference = $ErrorActionPreference
	try {
		$ErrorActionPreference = 'Continue'
		# As in Get-Reported: plain text, so the banner is not drawn as an error.
		$versionOutput = (& (Join-Path $pathEntry 'java.exe') -version 2>&1 |
			ForEach-Object { "$_" } | Out-String)
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
