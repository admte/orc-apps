$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Windows 10 1809 and Server 2019 share build 17763, Claude Code's minimum.
$os = Get-CimInstance -ClassName Win32_OperatingSystem
if ([version]$os.Version -lt [version]'10.0.17763') {
	throw "claude install: $($os.Caption) ($($os.Version)) is unsupported. Claude Code requires Windows Server 2019 or newer, or Windows 10 1809 or newer. Upgrade the pool's OS before retrying. See https://code.claude.com/docs/en/setup"
}

function Save-ClaudeDownload {
	param([string]$Url, [string]$Path)

	# Native curl avoids Windows PowerShell 5.1's legacy .NET TLS defaults.
	# Skip revocation fetches that can fail on a fresh guest; certificate trust
	# and hostname validation remain enabled, and the archive is checked below.
	$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
	if (Test-Path -LiteralPath $curl -PathType Leaf) {
		& $curl --fail --location --silent --show-error --ssl-no-revoke `
			--retry 3 --retry-delay 3 --connect-timeout 30 --max-time 300 `
			--output $Path $Url
		if ($LASTEXITCODE -eq 0) { return }
		Write-Warning "claude install: curl.exe download failed (exit $LASTEXITCODE); retrying with PowerShell"
	}

	[Net.ServicePointManager]::SecurityProtocol = `
		[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
	for ($attempt = 1; $attempt -le 3; $attempt++) {
		try {
			Invoke-WebRequest -UseBasicParsing -TimeoutSec 300 -Uri $Url -OutFile $Path
			return
		} catch {
			if ($attempt -eq 3) {
				throw "claude install: failed to download ${Url}: $($_.Exception.Message)"
			}
			Start-Sleep -Seconds 3
		}
	}
}

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
	Save-ClaudeDownload -Url "$baseUrl/$archive" -Path $archivePath
	Save-ClaudeDownload -Url "$baseUrl/SHASUMS256.txt" -Path $checksumsPath

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
