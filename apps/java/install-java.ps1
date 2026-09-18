$ErrorActionPreference = 'Stop'

if (-not $env:APP_VERSION) {
	throw 'java install: APP_VERSION is required'
}
if ($env:APP_VERSION -notmatch '^\d+\.\d+\.\d+$') {
	throw "java install: invalid APP_VERSION: $env:APP_VERSION"
}
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

# APP_VERSION is the release; [X,X.1) resolves its newest build for this node.
$range = [uri]::EscapeDataString("[$($env:APP_VERSION),$($env:APP_VERSION).1)")
$names = Invoke-RestMethod -UseBasicParsing -Uri (
	"$api/info/release_names?release_type=ga&version=$range&$selector" +
	'&page_size=1&sort_method=DEFAULT&sort_order=DESC'
)
$release = @($names.releases) | Select-Object -First 1
if (-not $release) {
	throw "java install: Adoptium publishes no $env:APP_VERSION release for windows/$architecture"
}
if ($release -match '^jdk8u(\d+)-b\d+$') {
	# Java 8 reports 1.8.0_<security>.
	$expectedVersion = "1.8.0_$($Matches[1])"
} elseif ($release -match '^jdk-\d+(\.\d+)*\+') {
	$expectedVersion = $env:APP_VERSION
} else {
	throw "java install: unexpected release name from Adoptium: $release"
}

$binaryUrl = "$api/binary/version/$release/windows/$architecture/jdk/hotspot/normal/eclipse?project=jdk"
$checksumUrl = "$api/checksum/version/$release/windows/$architecture/jdk/hotspot/normal/eclipse?project=jdk"
$root = Join-Path $env:ProgramFiles 'java'
$prefix = Join-Path $root $env:APP_VERSION
$current = Join-Path $root 'current'
$pathEntry = Join-Path $current 'bin'
$work = Join-Path ([System.IO.Path]::GetTempPath()) "java-$([guid]::NewGuid())"

try {
	New-Item -ItemType Directory -Path $work -Force | Out-Null
	$archive = Join-Path $work 'jdk.zip'
	Invoke-WebRequest -UseBasicParsing -Uri $binaryUrl -OutFile $archive
	$checksumResponse = Invoke-WebRequest -UseBasicParsing -Uri $checksumUrl
	$expected = (($checksumResponse.Content.Trim() -split '\s+')[0]).ToLowerInvariant()
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
		throw "java install: installed version does not match $env:APP_VERSION`: $versionOutput"
	}
	Write-Host $versionOutput.Trim()
} finally {
	Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
