$ErrorActionPreference = 'Stop'

$existing = Get-Command agent -ErrorAction SilentlyContinue
if ($existing -and -not $env:CURSOR_FORCE_INSTALL) {
	& $existing.Source --version
	if ($LASTEXITCODE -ne 0) {
		throw "cursor install: existing CLI failed with exit code $LASTEXITCODE"
	}
	exit 0
}

if ($env:PROCESSOR_ARCHITECTURE -notin @('AMD64', 'ARM64')) {
	throw "cursor install: unsupported architecture $env:PROCESSOR_ARCHITECTURE"
}
if (-not $env:USERPROFILE) {
	throw 'cursor install: USERPROFILE is required'
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "cursor-$([guid]::NewGuid())"
try {
	New-Item -ItemType Directory -Path $tmp -Force | Out-Null
	$installer = Join-Path $tmp 'install.ps1'
	Write-Host 'Downloading the official Cursor CLI installer'
	Invoke-WebRequest -UseBasicParsing -Uri 'https://cursor.com/install?win32=true' -OutFile $installer
	& $installer
	if ($LASTEXITCODE -ne 0) {
		throw "cursor install: official installer failed with exit code $LASTEXITCODE"
	}

	$command = Get-Command agent -ErrorAction SilentlyContinue
	if ($command) {
		$agent = $command.Source
	} else {
		$candidates = @(
			(Join-Path $env:USERPROFILE '.local\bin\agent.exe'),
			(Join-Path $env:USERPROFILE '.local\bin\agent.cmd')
		)
		$agent = $candidates | Where-Object {
			Test-Path -LiteralPath $_ -PathType Leaf
		} | Select-Object -First 1
	}
	if (-not $agent) {
		throw 'cursor install: official installer did not create the agent command'
	}
	& $agent --version
	if ($LASTEXITCODE -ne 0) {
		throw "cursor install: installed CLI failed with exit code $LASTEXITCODE"
	}
} finally {
	Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
