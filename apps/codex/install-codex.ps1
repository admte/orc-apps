$ErrorActionPreference = 'Stop'

$existing = Get-Command codex -ErrorAction SilentlyContinue
if ($existing -and -not $env:APP_VERSION -and -not $env:CODEX_FORCE_INSTALL) {
	& $existing.Source --version
	if ($LASTEXITCODE -ne 0) {
		throw "codex install: existing CLI failed with exit code $LASTEXITCODE"
	}
	exit 0
}

$architecture = switch ($env:PROCESSOR_ARCHITECTURE) {
	'AMD64' { 'x86_64' }
	'ARM64' { 'aarch64' }
	default { throw "codex install: unsupported architecture $env:PROCESSOR_ARCHITECTURE" }
}
$archive = "codex-package-$architecture-pc-windows-msvc.tar.gz"
$baseUrl = if ($env:APP_VERSION) {
	$version = $env:APP_VERSION -replace '^rust-v', '' -replace '^v', ''
	"https://github.com/openai/codex/releases/download/rust-v$version"
} else {
	'https://github.com/openai/codex/releases/latest/download'
}
$installDir = if ($env:CODEX_INSTALL_DIR) {
	$env:CODEX_INSTALL_DIR
} else {
	Join-Path $env:USERPROFILE '.local\bin'
}
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "codex-$([guid]::NewGuid())"

try {
	if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue)) {
		throw 'codex install: tar.exe is required'
	}
	New-Item -ItemType Directory -Path $tmp -Force | Out-Null
	$archivePath = Join-Path $tmp $archive
	$checksumsPath = Join-Path $tmp 'SHA256SUMS'
	Write-Host "Downloading Codex CLI for $architecture-pc-windows-msvc"
	Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/$archive" -OutFile $archivePath
	Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/codex-package_SHA256SUMS" -OutFile $checksumsPath

	$checksumLine = Get-Content $checksumsPath |
		Where-Object { $_ -match "^[0-9a-fA-F]{64}\s+\*?$([regex]::Escape($archive))$" } |
		Select-Object -First 1
	if (-not $checksumLine) {
		throw "codex install: checksum for $archive was not published"
	}
	$expected = ($checksumLine -split '\s+')[0].ToLowerInvariant()
	$actual = (Get-FileHash -Algorithm SHA256 $archivePath).Hash.ToLowerInvariant()
	if ($actual -ne $expected) {
		throw "codex install: checksum verification failed for $archive"
	}

	& tar.exe -xzf $archivePath -C $tmp
	if ($LASTEXITCODE -ne 0) {
		throw "codex install: failed to extract $archive"
	}
	$source = Join-Path $tmp 'bin\codex.exe'
	if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
		throw "codex install: Codex CLI binary is missing from $archive"
	}

	New-Item -ItemType Directory -Path $installDir -Force | Out-Null
	$packageDir = Join-Path $installDir '.codex-package'
	Remove-Item -LiteralPath $packageDir -Recurse -Force -ErrorAction SilentlyContinue
	New-Item -ItemType Directory -Path $packageDir -Force | Out-Null
	foreach ($entry in @('bin', 'codex-package.json', 'codex-path', 'codex-resources')) {
		Copy-Item -LiteralPath (Join-Path $tmp $entry) -Destination $packageDir -Recurse -Force
	}

	$launcher = Join-Path $installDir 'codex.cmd'
	$launcherContents = "@echo off`r`n`"%~dp0.codex-package\bin\codex.exe`" %*`r`n"
	[System.IO.File]::WriteAllText(
		$launcher,
		$launcherContents,
		[System.Text.Encoding]::ASCII
	)

	$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
	$pathEntries = @($userPath -split ';' | Where-Object { $_ })
	if ($installDir -notin $pathEntries) {
		[Environment]::SetEnvironmentVariable(
			'Path',
			(@($pathEntries) + $installDir) -join ';',
			'User'
		)
	}

	& $launcher --version
	if ($LASTEXITCODE -ne 0) {
		throw "codex install: installed CLI failed with exit code $LASTEXITCODE"
	}
} finally {
	Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
