$ErrorActionPreference = 'Stop'

if (-not $env:APP_VERSION) {
	throw 'node install: APP_VERSION is required'
}
if (-not $env:ProgramFiles) {
	throw 'node install: ProgramFiles is required'
}

$version = $env:APP_VERSION.TrimStart('v')
if ($version -notmatch '^\d+\.\d+\.\d+$') {
	throw "node install: invalid APP_VERSION: $env:APP_VERSION"
}
$architecture = switch ($env:PROCESSOR_ARCHITECTURE) {
	'AMD64' { 'x64' }
	'ARM64' { 'arm64' }
	default { throw "node install: unsupported architecture $env:PROCESSOR_ARCHITECTURE" }
}
$asset = "node-v$version-win-$architecture.zip"
$base = "https://nodejs.org/dist/v$version"
$root = Join-Path $env:ProgramFiles 'node'
$prefix = Join-Path $root $version
$current = Join-Path $root 'current'
$work = Join-Path ([System.IO.Path]::GetTempPath()) "node-$([guid]::NewGuid())"

try {
	New-Item -ItemType Directory -Path $work -Force | Out-Null
	$archive = Join-Path $work $asset
	$sums = Join-Path $work 'SHASUMS256.txt'
	Invoke-WebRequest -UseBasicParsing -Uri "$base/$asset" -OutFile $archive
	Invoke-WebRequest -UseBasicParsing -Uri "$base/SHASUMS256.txt" -OutFile $sums

	$line = Get-Content $sums |
		Where-Object { $_ -match "^[0-9a-fA-F]{64}\s+\*?$([regex]::Escape($asset))$" } |
		Select-Object -First 1
	if (-not $line) {
		throw "node install: checksum for $asset was not published"
	}
	$expected = ($line -split '\s+')[0].ToLowerInvariant()
	$actual = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant()
	if ($actual -ne $expected) {
		throw "node install: checksum verification failed for $asset"
	}

	$unpacked = Join-Path $work 'unpacked'
	Expand-Archive -LiteralPath $archive -DestinationPath $unpacked
	$source = Join-Path $unpacked "node-v$version-win-$architecture"
	if (-not (Test-Path -LiteralPath (Join-Path $source 'node.exe') -PathType Leaf)) {
		throw "node install: node.exe is missing from $asset"
	}

	New-Item -ItemType Directory -Path $root -Force | Out-Null
	Remove-Item -LiteralPath $prefix -Recurse -Force -ErrorAction SilentlyContinue
	Move-Item -LiteralPath $source -Destination $prefix

	if (Test-Path -LiteralPath $current) {
		$item = Get-Item -LiteralPath $current -Force
		if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
			throw "node install: $current exists and is not a junction"
		}
		[IO.Directory]::Delete($current)
	}
	New-Item -ItemType Junction -Path $current -Target $prefix | Out-Null

	$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
	$entries = @($machinePath -split ';' | Where-Object { $_ })
	if ($current -notin $entries) {
		[Environment]::SetEnvironmentVariable(
			'Path',
			(@($entries) + $current) -join ';',
			'Machine'
		)
	}

	$actualVersion = & (Join-Path $current 'node.exe') --version
	$reported = $actualVersion.Trim()
	if ($LASTEXITCODE -ne 0 -or
		($reported -ne "v$version" -and -not $reported.StartsWith("v$version-"))) {
		throw "node install: installed version '$actualVersion' does not match $version"
	}
} finally {
	Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
