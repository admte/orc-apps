$ErrorActionPreference = 'Stop'

$existing = Get-Command claude -ErrorAction SilentlyContinue
if ($existing -and -not $env:APP_VERSION -and -not $env:CLAUDE_CODE_FORCE_INSTALL) {
	& $existing.Source --version
	if ($LASTEXITCODE -ne 0) {
		throw "claude install: existing CLI failed with exit code $LASTEXITCODE"
	}
	exit 0
}

$architecture = switch ($env:PROCESSOR_ARCHITECTURE) {
	'AMD64' { 'x64' }
	'ARM64' { 'arm64' }
	default { throw "claude install: unsupported architecture $env:PROCESSOR_ARCHITECTURE" }
}
$archive = "claude-win32-$architecture.zip"
$baseUrl = if ($env:APP_VERSION) {
	$version = $env:APP_VERSION.TrimStart('v')
	"https://github.com/anthropics/claude-code/releases/download/v$version"
} else {
	'https://github.com/anthropics/claude-code/releases/latest/download'
}
$installDir = if ($env:CLAUDE_INSTALL_DIR) {
	$env:CLAUDE_INSTALL_DIR
} else {
	Join-Path $env:USERPROFILE '.local\bin'
}
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "claude-$([guid]::NewGuid())"

try {
	New-Item -ItemType Directory -Path $tmp -Force | Out-Null
	$archivePath = Join-Path $tmp $archive
	$checksumsPath = Join-Path $tmp 'SHASUMS256.txt'
	Write-Host "Downloading Claude Code for windows/$architecture"
	Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/$archive" -OutFile $archivePath
	Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/SHASUMS256.txt" -OutFile $checksumsPath

	$checksumLine = Get-Content $checksumsPath |
		Where-Object { $_ -match "^[0-9a-fA-F]{64}\s+\*?$([regex]::Escape($archive))$" } |
		Select-Object -First 1
	if (-not $checksumLine) {
		throw "claude install: checksum for $archive was not published"
	}
	$expected = ($checksumLine -split '\s+')[0].ToLowerInvariant()
	$actual = (Get-FileHash -Algorithm SHA256 $archivePath).Hash.ToLowerInvariant()
	if ($actual -ne $expected) {
		throw "claude install: checksum verification failed for $archive"
	}

	$unpacked = Join-Path $tmp 'unpacked'
	Expand-Archive -Path $archivePath -DestinationPath $unpacked
	$source = Get-ChildItem -Path $unpacked -Filter claude.exe -Recurse |
		Select-Object -First 1
	if (-not $source) {
		throw "claude install: Claude Code binary is missing from $archive"
	}

	New-Item -ItemType Directory -Path $installDir -Force | Out-Null
	$claude = Join-Path $installDir 'claude.exe'
	Copy-Item -LiteralPath $source.FullName -Destination $claude -Force

	$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
	$pathEntries = @($userPath -split ';' | Where-Object { $_ })
	if ($installDir -notin $pathEntries) {
		[Environment]::SetEnvironmentVariable(
			'Path',
			(@($pathEntries) + $installDir) -join ';',
			'User'
		)
	}

	& $claude --version
	if ($LASTEXITCODE -ne 0) {
		throw "claude install: installed CLI failed with exit code $LASTEXITCODE"
	}
} finally {
	Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
