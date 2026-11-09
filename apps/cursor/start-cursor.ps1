<#
.SYNOPSIS
Checks that the Cursor CLI runs and, given a key file, that the API key authenticates.

.PARAMETER ApiKeyFile
File holding the Cursor API key.

.PARAMETER AgentBin
The agent command to check (default: agent on PATH).
#>
[CmdletBinding()]
param(
	[string]$ApiKeyFile = '',
	[string]$AgentBin = ''
)

$ErrorActionPreference = 'Stop'

if ($AgentBin -and (Test-Path -LiteralPath $AgentBin -PathType Leaf)) {
	$agent = $AgentBin
} else {
	$command = Get-Command agent -ErrorAction SilentlyContinue
	if ($command) {
		$agent = $command.Source
	} else {
		# The official installer puts the CLI under LOCALAPPDATA and adds it only to
		# the user's PATH, which a process started before the install does not see.
		$candidates = @(
			(Join-Path $env:LOCALAPPDATA 'cursor-agent\agent.exe'),
			(Join-Path $env:LOCALAPPDATA 'cursor-agent\agent.cmd'),
			(Join-Path $env:USERPROFILE '.local\bin\agent.exe'),
			(Join-Path $env:USERPROFILE '.local\bin\agent.cmd')
		)
		$agent = $candidates | Where-Object {
			Test-Path -LiteralPath $_ -PathType Leaf
		} | Select-Object -First 1
	}
}
if (-not $agent) {
	throw 'cursor start: Cursor CLI is not installed'
}
& $agent --version | Out-Null
if ($LASTEXITCODE -ne 0) {
	throw "cursor start: CLI version check failed with exit code $LASTEXITCODE"
}

# The CLI is an interactive TUI, not a service: launching it headless exits
# immediately, so start only verifies the install and, when a key is
# provided, that the key authenticates.
$keyFile = $ApiKeyFile
if (-not $keyFile) {
	Write-Host 'Cursor CLI is ready; API key was not provided'
	exit 0
}
if (-not (Test-Path -LiteralPath $keyFile -PathType Leaf)) {
	throw 'cursor start: the API key file is not readable'
}
$env:CURSOR_API_KEY = ([System.IO.File]::ReadAllText($keyFile)).TrimEnd([char[]]"`r`n")
if (-not $env:CURSOR_API_KEY) {
	throw 'cursor start: cursor_api_key is empty'
}
& $agent status | Out-Null
if ($LASTEXITCODE -ne 0) {
	throw "cursor start: Cursor API key validation failed with exit code $LASTEXITCODE"
}
Write-Host 'Cursor CLI API key validated'
