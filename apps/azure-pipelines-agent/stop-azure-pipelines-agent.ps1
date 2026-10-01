$ErrorActionPreference = 'Stop'

# Quiesce hook: the agent is still running and may be mid-job. Disable it through
# the API so the pool stops routing work here, then wait for the worker already
# running to finish. The wait belongs to this command rather than to the signal
# that follows: only this command gets the whole stop.timeout.

$JobTimeout = if ($env:JOB_TIMEOUT) { [int]$env:JOB_TIMEOUT } else { 3540 }
$PollInterval = if ($env:POLL_INTERVAL) { [int]$env:POLL_INTERVAL } else { 10 }
$ApiVersion = if ($env:AZP_API_VERSION) { $env:AZP_API_VERSION } else { '7.1' }

function Write-Note($message) {
	Write-Host "azure-pipelines-agent stop: $message"
}

function Get-TokenValue {
	if ($env:TOKEN_FILE) {
		return (Get-Content -Raw -LiteralPath $env:TOKEN_FILE).Trim()
	}
	if ($env:TOKEN) {
		return $env:TOKEN.Trim()
	}
	return $null
}

function Get-AuthHeader($token) {
	$pair = [Text.Encoding]::ASCII.GetBytes(":$token")
	return @{ Authorization = "Basic $([Convert]::ToBase64String($pair))" }
}

$workDir = Join-Path (Get-Location) 'azure-pipelines-agent'
if (-not (Test-Path -LiteralPath (Join-Path $workDir 'config.cmd') -PathType Leaf)) {
	Write-Note "no install found; nothing to quiesce dir=$workDir"
	exit 0
}

$agentName = [System.Net.Dns]::GetHostName()
$agentPool = if ($env:AGENT_POOL) { $env:AGENT_POOL } else { $env:POOL }
$token = Get-TokenValue
$org = if ($env:URL) { $env:URL.TrimEnd('/') } else { $null }

if (-not $token -or -not $org -or -not $agentPool) {
	Write-Note "no URL, token or pool; waiting for the job only name=$agentName"
} else {
	try {
		Write-Note "disabling the agent so no new job is routed here name=$agentName pool=$agentPool"
		$headers = Get-AuthHeader $token
		$poolQuery = [uri]::EscapeDataString($agentPool)
		$pool = Invoke-RestMethod -Headers $headers `
			-Uri "$org/_apis/distributedtask/pools?poolName=$poolQuery&api-version=$ApiVersion"
		$poolId = @($pool.value)[0].id
		if (-not $poolId) { throw "agent pool not found name=$agentPool" }
		$agentQuery = [uri]::EscapeDataString($agentName)
		$agents = Invoke-RestMethod -Headers $headers `
			-Uri "$org/_apis/distributedtask/pools/$poolId/agents?agentName=$agentQuery&api-version=$ApiVersion"
		$agentId = @($agents.value)[0].id
		if (-not $agentId) { throw "agent is not registered name=$agentName" }
		Invoke-RestMethod -Method Patch -Headers $headers -ContentType 'application/json' `
			-Body (@{ id = $agentId; enabled = $false } | ConvertTo-Json -Compress) `
			-Uri "$org/_apis/distributedtask/pools/$poolId/agents/$agentId`?api-version=$ApiVersion" | Out-Null
	} catch {
		Write-Note "could not disable the agent; waiting for the job anyway name=$agentName error=$($_.Exception.Message)"
	}
}

# A job runs in Agent.Worker, a child the agent host spawns out of its own
# directory. A worker whose path cannot be read is still a worker: assume it is
# ours rather than letting the runtime kill it.
function Test-WorkerRunning {
	try {
		$workers = @(Get-CimInstance Win32_Process -Filter "Name='Agent.Worker.exe'")
	} catch {
		return $true
	}
	foreach ($worker in $workers) {
		if (-not $worker.ExecutablePath) { return $true }
		if ($worker.ExecutablePath.StartsWith($workDir, [StringComparison]::OrdinalIgnoreCase)) {
			return $true
		}
	}
	return $false
}

if (-not (Test-WorkerRunning)) {
	Write-Note "no job in flight; safe to stop name=$agentName"
	exit 0
}

Write-Note "waiting for the current job to finish name=$agentName timeout=${JobTimeout}s"
$waited = 0
while (Test-WorkerRunning) {
	if ($waited -ge $JobTimeout) {
		throw "azure-pipelines-agent stop: job was still running after ${JobTimeout}s name=$agentName"
	}
	Start-Sleep -Seconds $PollInterval
	$waited += $PollInterval
}

Write-Note "job finished; safe to stop name=$agentName waited=${waited}s"
