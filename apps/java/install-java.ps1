$ErrorActionPreference = 'Stop'

if (-not $env:APP_VERSION) {
	throw 'java install: APP_VERSION is required'
}
if (-not $env:ProgramFiles) {
	throw 'java install: ProgramFiles is required'
}

$architecture = switch ($env:PROCESSOR_ARCHITECTURE) {
	'AMD64' { 'x64' }
	'ARM64' { 'aarch64' }
	default { throw "java install: unsupported architecture $env:PROCESSOR_ARCHITECTURE" }
}
if ($env:APP_VERSION -match '^8u\d+-b\d+$') {
	$release = "jdk$($env:APP_VERSION)"
	$security = ($env:APP_VERSION -replace '^8u', '') -replace '-b\d+$', ''
	$expectedVersion = "1.8.0_$security"
} elseif ($env:APP_VERSION -match '^(\d+\.\d+\.\d+)_(\d+)$') {
	$release = "jdk-$($Matches[1])+$($Matches[2])"
	$expectedVersion = $Matches[1]
} else {
	throw "java install: unsupported Temurin version format: $env:APP_VERSION"
}

$api = 'https://api.adoptium.net/v3'
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
