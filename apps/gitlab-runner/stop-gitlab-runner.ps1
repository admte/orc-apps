$ErrorActionPreference = 'Stop'

# Quiesce hook, Windows only. On Linux the declared SIGQUIT is gitlab-runner's own
# graceful shutdown and no script is needed; Windows has no such signal, so the
# wait for the job in flight happens here, before the runtime kills the process.
#
# This waits for the current job; it cannot stop GitLab from handing out one more,
# because taking a runner out of rotation needs an API token this app is not given.

$JobTimeout = if ($env:JOB_TIMEOUT) { [int]$env:JOB_TIMEOUT } else { 3540 }
$PollInterval = if ($env:POLL_INTERVAL) { [int]$env:POLL_INTERVAL } else { 10 }

function Write-Note($message) {
	Write-Host "gitlab-runner stop: $message"
}

if (-not $env:APP_PID) {
	Write-Note 'no runner process to wait for'
	exit 0
}

# A job runs in a process the runner spawns; no children means no job in flight.
function Test-JobRunning {
	$children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($env:APP_PID)" -ErrorAction SilentlyContinue)
	return $children.Count -gt 0
}

if (-not (Test-JobRunning)) {
	Write-Note "no job in flight; safe to stop pid=$($env:APP_PID)"
	exit 0
}

Write-Note "waiting for the current job to finish pid=$($env:APP_PID) timeout=${JobTimeout}s"
$waited = 0
while (Test-JobRunning) {
	if ($waited -ge $JobTimeout) {
		throw "gitlab-runner stop: job was still running after ${JobTimeout}s pid=$($env:APP_PID)"
	}
	Start-Sleep -Seconds $PollInterval
	$waited += $PollInterval
}

Write-Note "job finished; safe to stop waited=${waited}s"
