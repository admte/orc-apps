$ErrorActionPreference = 'Stop'

# Post-exit hook: the runner is already gone, so GitLab will not refuse the removal
# as busy. The registration is released on APP_STOP_REASON=terminate and on nothing
# else — a restart or a plain stop leaves this node's runner manager in place.

$Attempts = if ($env:ATTEMPTS) { [int]$env:ATTEMPTS } else { 3 }
$RetryInterval = if ($env:RETRY_INTERVAL) { [int]$env:RETRY_INTERVAL } else { 5 }

function Write-Note($message) {
	Write-Host "gitlab-runner stopped: $message"
}

$reason = if ($env:APP_STOP_REASON) { $env:APP_STOP_REASON } else { 'exit' }
if ($reason -ne 'terminate') {
	Write-Note "keeping the runner registration reason=$reason"
	exit 0
}

$config = Join-Path (Join-Path (Get-Location) 'gitlab-runner') 'config.toml'
if (-not (Test-Path -LiteralPath $config)) {
	Write-Note "no registration found; nothing to release config=$config"
	exit 0
}

$runner = Join-Path (Join-Path $env:ProgramFiles 'gitlab-runner') 'current\gitlab-runner.exe'
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
	Write-Note 'the runner binary is gone; nothing to release'
	exit 0
}

for ($attempt = 1; ; $attempt++) {
	Write-Note "unregistering the runner reason=$reason attempt=$attempt/$Attempts"
	& $runner unregister --config $config --all-runners
	if ($LASTEXITCODE -eq 0) {
		Write-Note "runner unregistered reason=$reason"
		exit 0
	}
	if ($attempt -ge $Attempts) {
		throw "gitlab-runner stopped: failed to unregister the runner after $Attempts attempts"
	}
	Start-Sleep -Seconds $RetryInterval
}
