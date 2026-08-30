$ErrorActionPreference = 'Stop'

# Quiesce hook: the listener is still running and may be mid-job. Take the pool
# label off the runner so the queue stops routing work here, then wait for the
# worker that is already running to finish, then exit 0. Stopping the listener is
# the runtime's next step; deregistering is stopped-github-runner.ps1's, and only
# when the node is going away for good.

# Kept under the 1h stop.timeout so the wait ends with a message of its own
# rather than being cut off mid-poll.
$jobTimeout = if ($env:JOB_TIMEOUT) { [int]$env:JOB_TIMEOUT } else { 3540 }
$pollInterval = if ($env:POLL_INTERVAL) { [int]$env:POLL_INTERVAL } else { 10 }

function Get-Token {
	if ($env:TOKEN_FILE) {
		return (Get-Content -Raw -LiteralPath $env:TOKEN_FILE).Trim()
	}
	if ($env:TOKEN) {
		return $env:TOKEN.Trim()
	}
	throw 'TOKEN_FILE or TOKEN is required'
}

function Get-GitHubApiPath {
	if (-not $env:URL -or -not $env:URL.StartsWith('https://github.com/')) {
		throw 'URL must start with https://github.com/'
	}
	$path = $env:URL.Substring('https://github.com/'.Length).TrimEnd('/')
	if ($path.EndsWith('.git')) {
		$path = $path.Substring(0, $path.Length - 4)
	}
	$parts = $path.Split('/', 2)
	if (-not $parts[0]) {
		throw 'GitHub owner is required'
	}
	if ($parts.Length -eq 2 -and $parts[1]) {
		return "repos/$($parts[0])/$($parts[1])"
	}
	return "orgs/$($parts[0])"
}

# The API pages at 100; an org can register far more runners than that, so walk
# pages until one comes back short or the name is found.
function Find-RunnerId($apiPath, $headers, $name) {
	for ($page = 1; $page -le 20; $page++) {
		$response = Invoke-RestMethod -Headers $headers `
			-Uri "https://api.github.com/$apiPath/actions/runners?per_page=100&page=$page"
		$match = $response.runners | Where-Object { $_.name -eq $name } | Select-Object -First 1
		if ($match) { return $match.id }
		if ($response.runners.Count -lt 100) { return $null }
	}
	return $null
}

# A job runs in Runner.Worker.exe, a child the listener spawns out of its own
# directory; no worker means no job in flight.
function Test-WorkerRunning($runnerDir) {
	$workers = Get-Process -Name 'Runner.Worker' -ErrorAction SilentlyContinue
	foreach ($worker in $workers) {
		try {
			if ($worker.Path -and $worker.Path.StartsWith($runnerDir, [System.StringComparison]::OrdinalIgnoreCase)) {
				return $true
			}
		} catch {
			# A worker whose path cannot be read is still a worker; assume it is ours.
			return $true
		}
	}
	return $false
}

$workDir = 'github-runner'
if (-not (Test-Path (Join-Path $workDir 'config.cmd'))) {
	Write-Host "github-runner stop: no install found; nothing to quiesce dir=$workDir"
	exit 0
}
$workDir = (Resolve-Path $workDir).Path

$runnerName = $env:COMPUTERNAME
$label = $env:POOL
$headers = @{ Accept = 'application/vnd.github+json'; Authorization = "token $(Get-Token)" }
$apiPath = Get-GitHubApiPath

if (-not $label) {
	Write-Host "github-runner stop: no pool label to remove; relying on the service stop name=$runnerName"
} else {
	$runnerId = Find-RunnerId $apiPath $headers $runnerName
	if (-not $runnerId) {
		Write-Host "github-runner stop: runner is not registered; nothing to unlabel name=$runnerName"
	} else {
		Write-Host "github-runner stop: removing the pool label so no new job is routed here name=$runnerName id=$runnerId label=$label"
		try {
			Invoke-RestMethod -Method Delete -Headers $headers `
				-Uri "https://api.github.com/$apiPath/actions/runners/$runnerId/labels/$label" | Out-Null
		} catch {
			Write-Host "github-runner stop: label removal failed; continuing to wait for the current job name=$runnerName label=$label"
		}
	}
}

if (-not (Test-WorkerRunning $workDir)) {
	Write-Host "github-runner stop: no job in flight; safe to stop name=$runnerName"
	exit 0
}

Write-Host "github-runner stop: waiting for the current job to finish name=$runnerName timeout=${jobTimeout}s"
$waited = 0
while (Test-WorkerRunning $workDir) {
	if ($waited -ge $jobTimeout) {
		throw "github-runner stop: job was still running after ${jobTimeout}s name=$runnerName"
	}
	Start-Sleep -Seconds $pollInterval
	$waited += $pollInterval
}

Write-Host "github-runner stop: job finished; safe to stop name=$runnerName waited=${waited}s"
