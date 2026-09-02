$ErrorActionPreference = 'Stop'

if (-not $env:APP_VERSION) {
	throw 'go install: APP_VERSION is required'
}
if (-not $env:ProgramFiles) {
	throw 'go install: ProgramFiles is required'
}

$version = $env:APP_VERSION -replace '^go', ''
if ($version -notmatch '^\d+\.\d+(\.\d+)?$') {
	throw "go install: invalid APP_VERSION: $env:APP_VERSION"
}
$architecture = switch ($env:PROCESSOR_ARCHITECTURE) {
	'AMD64' { 'amd64' }
	'ARM64' { 'arm64' }
	default { throw "go install: unsupported architecture $env:PROCESSOR_ARCHITECTURE" }
}
$asset = "go$version.windows-$architecture.zip"
$root = Join-Path $env:ProgramFiles 'go'
$prefix = Join-Path $root $version
$current = Join-Path $root 'current'
$pathEntry = Join-Path $current 'bin'
$work = Join-Path ([System.IO.Path]::GetTempPath()) "go-$([guid]::NewGuid())"

try {
	New-Item -ItemType Directory -Path $work -Force | Out-Null
	$releases = Invoke-RestMethod -UseBasicParsing -Uri 'https://go.dev/dl/?mode=json&include=all'
	$release = $releases | Where-Object { $_.version -eq "go$version" } | Select-Object -First 1
	$file = $release.files | Where-Object {
		$_.filename -eq $asset -and $_.kind -eq 'archive'
	} | Select-Object -First 1
	if (-not $file -or -not $file.sha256) {
		throw "go install: checksum for $asset was not published"
	}

	$archive = Join-Path $work $asset
	Invoke-WebRequest -UseBasicParsing -Uri "https://go.dev/dl/$asset" -OutFile $archive
	$actual = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant()
	if ($actual -ne $file.sha256.ToLowerInvariant()) {
		throw "go install: checksum verification failed for $asset"
	}

	$unpacked = Join-Path $work 'unpacked'
	Expand-Archive -LiteralPath $archive -DestinationPath $unpacked
	$source = Join-Path $unpacked 'go'
	if (-not (Test-Path -LiteralPath (Join-Path $source 'bin\go.exe') -PathType Leaf)) {
		throw "go install: go.exe is missing from $asset"
	}

	New-Item -ItemType Directory -Path $root -Force | Out-Null
	Remove-Item -LiteralPath $prefix -Recurse -Force -ErrorAction SilentlyContinue
	Move-Item -LiteralPath $source -Destination $prefix

	if (Test-Path -LiteralPath $current) {
		$item = Get-Item -LiteralPath $current -Force
		if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
			throw "go install: $current exists and is not a junction"
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

	$actualVersion = & (Join-Path $pathEntry 'go.exe') version
	if ($LASTEXITCODE -ne 0 -or $actualVersion -notmatch " go$([regex]::Escape($version)) ") {
		throw "go install: installed version '$actualVersion' does not match $version"
	}
} finally {
	Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
