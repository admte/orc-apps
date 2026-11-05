<#
.SYNOPSIS
Checks that the Codex CLI runs and, given a key file, signs it in with the OpenAI API
key.

.PARAMETER ApiKeyFile
File holding the OpenAI API key.

.PARAMETER InstallDir
Where install put the codex launcher (default: .local\bin under the user profile).
#>
[CmdletBinding()]
param(
	[string]$ApiKeyFile = '',
	[string]$InstallDir = ''
)

$ErrorActionPreference = 'Stop'

$command = Get-Command codex -ErrorAction SilentlyContinue
if ($command) {
	$codex = $command.Source
} else {
	$installDir = if ($InstallDir) {
		$InstallDir
	} else {
		Join-Path $env:USERPROFILE '.local\bin'
	}
	$codex = Join-Path $installDir 'codex.cmd'
}
if (-not (Test-Path -LiteralPath $codex -PathType Leaf)) {
	throw 'codex configure: Codex CLI is not installed'
}
if ($env:CODEX_HOME) {
	New-Item -ItemType Directory -Path $env:CODEX_HOME -Force | Out-Null
}
& $codex --version | Out-Null
if ($LASTEXITCODE -ne 0) {
	throw "codex configure: CLI version check failed with exit code $LASTEXITCODE"
}

$keyFile = $ApiKeyFile
if (-not $keyFile) {
	Write-Host 'Codex CLI is ready; OpenAI API key was not provided'
	exit 0
}
if (-not (Test-Path -LiteralPath $keyFile -PathType Leaf)) {
	throw 'codex configure: the API key file is not readable'
}
$key = ([System.IO.File]::ReadAllText($keyFile)).TrimEnd([char[]]"`r`n")
if (-not $key) {
	throw 'codex configure: openai_api_key is empty'
}

$key | & $codex login --with-api-key
$key = $null
if ($LASTEXITCODE -ne 0) {
	throw "codex configure: API key login failed with exit code $LASTEXITCODE"
}
& $codex login status | Out-Null
if ($LASTEXITCODE -ne 0) {
	throw "codex configure: login status failed with exit code $LASTEXITCODE"
}
Write-Host 'Codex CLI API key configured'
