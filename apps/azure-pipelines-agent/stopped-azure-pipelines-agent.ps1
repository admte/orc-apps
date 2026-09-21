$ErrorActionPreference = 'Stop'

# Post-exit hook: the agent host is already gone, so Azure DevOps will not refuse
# the removal as busy. The registration is released on APP_STOP_REASON=terminate
# and on nothing else — a restart or a plain stop leaves this node's agent in
# place, because the same install starts again against the same registration.

$Attempts = if ($env:ATTEMPTS) { [int]$env:ATTEMPTS } else { 3 }
$RetryInterval = if ($env:RETRY_INTERVAL) { [int]$env:RETRY_INTERVAL } else { 5 }

function Write-Note($message) {
	Write-Host "azure-pipelines-agent stopped: $message"
}

function Get-TokenValue {
	if ($env:TOKEN_FILE) {
		return (Get-Content -Raw -LiteralPath $env:TOKEN_FILE).Trim()
	}
	if ($env:TOKEN) {
		return $env:TOKEN.Trim()
	}
	throw 'azure-pipelines-agent stopped: TOKEN_FILE or TOKEN is required'
}

$reason = if ($env:APP_STOP_REASON) { $env:APP_STOP_REASON } else { 'exit' }
if ($reason -ne 'terminate') {
	Write-Note "keeping the agent registration reason=$reason"
	exit 0
}

$workDir = Join-Path (Get-Location) 'azure-pipelines-agent'
if (-not (Test-Path -LiteralPath (Join-Path $workDir 'config.cmd') -PathType Leaf)) {
	Write-Note "no install found; nothing to deregister dir=$workDir"
	exit 0
}
if (-not (Test-Path -LiteralPath (Join-Path $workDir '.agent'))) {
	Write-Note "no registration found; nothing to deregister dir=$workDir"
	exit 0
}
Set-Location $workDir

$token = Get-TokenValue

for ($attempt = 1; ; $attempt++) {
	Write-Note "deregistering the agent reason=$reason attempt=$attempt/$Attempts"
	# The PAT goes through the environment rather than a --token flag, so it stays
	# out of the process list.
	$env:VSTS_AGENT_INPUT_TOKEN = $token
	try {
		& .\config.cmd remove --unattended --auth pat
		$removeExit = $LASTEXITCODE
	} finally {
		Remove-Item Env:VSTS_AGENT_INPUT_TOKEN -ErrorAction SilentlyContinue
	}
	if ($removeExit -eq 0) {
		Write-Note "agent deregistered reason=$reason"
		exit 0
	}
	if ($attempt -ge $Attempts) {
		throw "azure-pipelines-agent stopped: failed to deregister the agent after $Attempts attempts"
	}
	Start-Sleep -Seconds $RetryInterval
}
