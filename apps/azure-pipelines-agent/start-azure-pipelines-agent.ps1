$ErrorActionPreference = 'Stop'

# Start phase: registration is node identity, so it happens here — once per node —
# and never in install, whose output a pool bake snapshots into a shared image.

$ApiVersion = if ($env:AZP_API_VERSION) { $env:AZP_API_VERSION } else { '7.1' }

function Get-TokenValue {
	if ($env:TOKEN_FILE) {
		return (Get-Content -Raw -LiteralPath $env:TOKEN_FILE).Trim()
	}
	if ($env:TOKEN) {
		return $env:TOKEN.Trim()
	}
	throw 'azure-pipelines-agent start: TOKEN_FILE or TOKEN is required'
}

# Azure DevOps takes the PAT as HTTP basic auth with an empty user name.
function Get-AuthHeader($token) {
	$pair = [Text.Encoding]::ASCII.GetBytes(":$token")
	return @{ Authorization = "Basic $([Convert]::ToBase64String($pair))" }
}

$workDir = Join-Path (Get-Location) 'azure-pipelines-agent'
if (-not (Test-Path -LiteralPath (Join-Path $workDir 'config.cmd') -PathType Leaf)) {
	throw "azure-pipelines-agent start: no agent install found; install must run first dir=$workDir"
}
Set-Location $workDir

if (-not $env:URL -or -not $env:URL.StartsWith('https://')) {
	throw 'azure-pipelines-agent start: URL must start with https://'
}
$org = $env:URL.TrimEnd('/')
$token = Get-TokenValue
$headers = Get-AuthHeader $token

# The agent name is the host name (a pool member is `<pool>-<slot>`). The Azure
# DevOps pool it joins is the operator's agent_pool when given, and otherwise the
# ORC pool's own name.
$agentName = [System.Net.Dns]::GetHostName()
$agentPool = if ($env:AGENT_POOL) { $env:AGENT_POOL } else { $env:POOL }
if (-not $agentPool) {
	throw 'azure-pipelines-agent start: agent_pool is required when the node is not in a named pool'
}

# `.agent` is the file config.cmd writes when a directory has been configured; it
# and the `.credentials` beside it are this node's identity. Absent means the node
# has none yet, so register; present means an ordinary service restart, so the
# same identity is reused. The stopped hook's `config.cmd remove` deletes it.
if (Test-Path -LiteralPath (Join-Path $workDir '.agent')) {
	Write-Host "azure-pipelines-agent start: already registered; reusing this node's identity name=$agentName"
} else {
	Write-Host "azure-pipelines-agent start: registering name=$agentName pool=$agentPool"
	# Every config.cmd flag can be given as VSTS_AGENT_INPUT_<NAME>, so the token
	# goes through the environment rather than the process list.
	$env:VSTS_AGENT_INPUT_TOKEN = $token
	try {
		& .\config.cmd --unattended --url $org --auth pat --pool $agentPool `
			--agent $agentName --work _work --replace
		$configExit = $LASTEXITCODE
	} finally {
		Remove-Item Env:VSTS_AGENT_INPUT_TOKEN -ErrorAction SilentlyContinue
	}
	if ($configExit -ne 0) {
		throw "azure-pipelines-agent start: registration failed name=$agentName pool=$agentPool"
	}
}

# Puts the agent back into rotation: stop disables it through the API, and the
# registration outlives every stop reason but terminate, so a drained node would
# otherwise come back online disabled — healthy-looking and never given a job.
# Never fatal: an agent to enable by hand beats a node that will not start.
try {
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
		-Body (@{ id = $agentId; enabled = $true } | ConvertTo-Json -Compress) `
		-Uri "$org/_apis/distributedtask/pools/$poolId/agents/$agentId`?api-version=$ApiVersion" | Out-Null
	Write-Host "azure-pipelines-agent start: agent enabled name=$agentName id=$agentId"
} catch {
	Write-Host "azure-pipelines-agent start: could not enable the agent; starting anyway name=$agentName error=$($_.Exception.Message)"
}

# The agent runs as the account the runtime runs as; there is no unprivileged-user
# rule to satisfy on Windows.
Write-Host "azure-pipelines-agent start: starting the agent name=$agentName dir=$workDir"
& .\run.cmd
exit $LASTEXITCODE
