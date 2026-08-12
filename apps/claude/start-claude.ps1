$ErrorActionPreference = 'Stop'

$command = Get-Command claude -ErrorAction SilentlyContinue
if ($command) {
	$claude = $command.Source
} else {
	$installDir = if ($env:CLAUDE_INSTALL_DIR) {
		$env:CLAUDE_INSTALL_DIR
	} else {
		Join-Path $env:USERPROFILE '.local\bin'
	}
	$claude = Join-Path $installDir 'claude.exe'
}
if (-not (Test-Path -LiteralPath $claude -PathType Leaf)) {
	throw 'claude configure: Claude Code is not installed'
}
& $claude --version | Out-Null
if ($LASTEXITCODE -ne 0) {
	throw "claude configure: CLI version check failed with exit code $LASTEXITCODE"
}

$keyFile = $env:ANTHROPIC_API_KEY_FILE
if (-not $keyFile) {
	Write-Host 'Claude Code is ready; Anthropic API key was not provided'
	exit 0
}
if (-not (Test-Path -LiteralPath $keyFile -PathType Leaf)) {
	throw 'claude configure: ANTHROPIC_API_KEY_FILE is not readable'
}
$key = ([System.IO.File]::ReadAllText($keyFile)).TrimEnd([char[]]"`r`n")
if (-not $key) {
	throw 'claude configure: anthropic_api_key is empty'
}

$configDir = if ($env:CLAUDE_CONFIG_DIR) {
	$env:CLAUDE_CONFIG_DIR
} else {
	Join-Path $env:USERPROFILE '.claude'
}
$settingsPath = Join-Path $configDir 'settings.json'
New-Item -ItemType Directory -Path $configDir -Force | Out-Null

if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
	$settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
} else {
	$settings = [pscustomobject]@{}
}
if (-not $settings -or $settings -isnot [pscustomobject]) {
	throw 'claude configure: Claude settings must be a JSON object'
}
if (-not $settings.PSObject.Properties['env']) {
	$settings | Add-Member -NotePropertyName env -NotePropertyValue ([pscustomobject]@{})
} elseif ($null -eq $settings.env) {
	$settings.env = [pscustomobject]@{}
}
if ($settings.env -isnot [pscustomobject]) {
	throw 'claude configure: Claude settings env must be a JSON object'
}
$settings.env | Add-Member -NotePropertyName ANTHROPIC_API_KEY -NotePropertyValue $key -Force
$key = $null

$tmp = Join-Path $configDir ".settings-$([guid]::NewGuid())"
try {
	$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
	$json = $settings | ConvertTo-Json -Depth 100
	[System.IO.File]::WriteAllText($tmp, "$json`n", $utf8NoBom)
	Move-Item -LiteralPath $tmp -Destination $settingsPath -Force
} finally {
	Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}

Write-Host 'Claude Code API key configured'
