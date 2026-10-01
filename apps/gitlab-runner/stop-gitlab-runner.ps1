$ErrorActionPreference = 'Stop'

# Quiesce hook. Pause the runner through the API so the queue stops routing work
# here, then wait for the job in flight. The wait is Windows-only work: on Linux
# the declared SIGQUIT is gitlab-runner's own graceful shutdown and the Linux stop
# hook waits alongside it, while Windows has no such signal, so the runtime would
# otherwise kill the process mid-job. Deleting the runner is
# stopped-gitlab-runner.ps1's.

$JobTimeout = if ($env:JOB_TIMEOUT) { [int]$env:JOB_TIMEOUT } else { 3540 }
$PollInterval = if ($env:POLL_INTERVAL) { [int]$env:POLL_INTERVAL } else { 10 }
$FormType = 'application/x-www-form-urlencoded'

function Write-Note($message) {
	Write-Host "gitlab-runner stop: $message"
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

function Get-RunnerId($path) {
	if (-not (Test-Path -LiteralPath $path)) { return $null }
	$value = Get-Content -Raw -LiteralPath $path
	if (-not $value) { return $null }
	$value = $value.Trim()
	if (-not $value) { return $null }
	return $value
}

# APP_PID is the script the runtime started, and PowerShell has no exec, so
# gitlab-runner.exe is its child for the whole life of the service — counting the
# script's children would mean "a job is always running". The runner's own
# children are the jobs, so the runner process is what has to be found first.
function Get-RunnerProcessId {
	$root = (Join-Path $env:ProgramFiles 'gitlab-runner').TrimEnd('\')
	$found = @(Get-CimInstance Win32_Process -Filter "Name='gitlab-runner.exe'" |
		Where-Object {
			$_.ExecutablePath -and
			$_.ExecutablePath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
		})
	if ($found.Count -eq 0) { return $null }
	return $found[0].ProcessId
}

$runnerPid = Get-RunnerProcessId

function Test-JobRunning($ownerPid) {
	if (-not $ownerPid) { return $false }
	try {
		$children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$ownerPid")
	} catch {
		# A job whose processes cannot be listed is still a job; assume one is
		# running rather than letting the runtime kill it.
		return $true
	}
	return $children.Count -gt 0
}

$idFile = Join-Path (Join-Path (Get-Location) 'gitlab-runner') 'runner.id'
$runnerId = Get-RunnerId $idFile
if (-not $runnerId) {
	Write-Note 'no runner recorded; nothing to pause'
} else {
	$token = Get-TokenValue
	if (-not $token) {
		Write-Note "no access token; cannot pause the runner id=$runnerId"
	} elseif (-not $env:URL -or -not $env:URL.StartsWith('https://')) {
		Write-Note "no usable URL; cannot pause the runner id=$runnerId"
	} else {
		$uri = [uri]$env:URL
		try {
			Write-Note "pausing the runner so no new job is routed here id=$runnerId"
			# PowerShell only applies the form content type to POST, so a PUT whose
			# type is left out arrives with no body GitLab will parse.
			Invoke-RestMethod -Method Put -Headers @{ 'PRIVATE-TOKEN' = $token } `
				-ContentType $FormType -Body @{ paused = 'true' } `
				-Uri "$($uri.Scheme)://$($uri.Authority)/api/v4/runners/$runnerId" | Out-Null
		} catch {
			Write-Note "pause failed; waiting for the job anyway id=$runnerId error=$($_.Exception.Message)"
		}
	}
}

if (-not $runnerPid) {
	Write-Note 'no runner process to wait for'
	exit 0
}

if (-not (Test-JobRunning $runnerPid)) {
	Write-Note "no job in flight; safe to stop pid=$runnerPid"
	exit 0
}

Write-Note "waiting for the current job to finish pid=$runnerPid timeout=${JobTimeout}s"
$waited = 0
while (Test-JobRunning $runnerPid) {
	if ($waited -ge $JobTimeout) {
		throw "gitlab-runner stop: job was still running after ${JobTimeout}s pid=$runnerPid"
	}
	Start-Sleep -Seconds $PollInterval
	$waited += $PollInterval
}

Write-Note "job finished; safe to stop waited=${waited}s"
