$ErrorActionPreference = 'Stop'

# Post-exit hook: the runner process is already gone. The runner is deleted from
# GitLab on APP_STOP_REASON=terminate and on nothing else — a restart or a plain
# stop leaves it in place and start resumes it.
#
# Order matters. The runner is deleted through the API first, while config.toml
# still holds the only other copy of its authentication token; unregister and the
# removal of config.toml come after. Clearing the local state is also what makes
# the next start create a fresh runner instead of coming up against one GitLab no
# longer has — a node in that state looks healthy and is never given another job.
#
# `unregister` alone would not do: a runner created through the API survives it —
# unregister removes this node's runner manager and the runner itself stays.

$Attempts = if ($env:ATTEMPTS) { [int]$env:ATTEMPTS } else { 3 }
$RetryInterval = if ($env:RETRY_INTERVAL) { [int]$env:RETRY_INTERVAL } else { 5 }

function Write-Note($message) {
	Write-Host "gitlab-runner stopped: $message"
}

function Get-TokenValue {
	if ($env:TOKEN_FILE) {
		return (Get-Content -Raw -LiteralPath $env:TOKEN_FILE).Trim()
	}
	if ($env:TOKEN) {
		return $env:TOKEN.Trim()
	}
	throw 'gitlab-runner stopped: TOKEN_FILE or TOKEN is required'
}

function Get-RunnerId($path) {
	if (-not (Test-Path -LiteralPath $path)) { return $null }
	$value = Get-Content -Raw -LiteralPath $path
	if (-not $value) { return $null }
	$value = $value.Trim()
	if (-not $value) { return $null }
	return $value
}

$reason = if ($env:APP_STOP_REASON) { $env:APP_STOP_REASON } else { 'exit' }
if ($reason -ne 'terminate') {
	Write-Note "keeping the runner reason=$reason"
	exit 0
}

$workDir = Join-Path (Get-Location) 'gitlab-runner'
$config = Join-Path $workDir 'config.toml'
$idFile = Join-Path $workDir 'runner.id'
$runnerId = Get-RunnerId $idFile
if (-not $runnerId) {
	Write-Note 'no runner recorded; nothing to delete'
	exit 0
}

if (-not $env:URL -or -not $env:URL.StartsWith('https://')) {
	throw 'gitlab-runner stopped: URL must start with https://'
}
$uri = [uri]$env:URL
$api = "$($uri.Scheme)://$($uri.Authority)/api/v4"
$headers = @{ 'PRIVATE-TOKEN' = Get-TokenValue }

for ($attempt = 1; ; $attempt++) {
	Write-Note "deleting the runner reason=$reason id=$runnerId attempt=$attempt/$Attempts"
	try {
		Invoke-RestMethod -Method Delete -Headers $headers -Uri "$api/runners/$runnerId" | Out-Null
		break
	} catch {
		if ($attempt -ge $Attempts) {
			throw "gitlab-runner stopped: failed to delete the runner after $Attempts attempts id=$runnerId"
		}
		Start-Sleep -Seconds $RetryInterval
	}
}

# The runner is gone from GitLab, so the local state is dead weight; clearing it
# is what lets the next start create a new one. unregister is best-effort — the
# removal below is what the next start actually reads.
$root = Join-Path $env:ProgramFiles 'gitlab-runner'
$runner = Join-Path (Join-Path $root $env:APP_VERSION) 'gitlab-runner.exe'
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
	$runner = Join-Path (Join-Path $root 'current') 'gitlab-runner.exe'
}
if ((Test-Path -LiteralPath $runner -PathType Leaf) -and (Test-Path -LiteralPath $config)) {
	& $runner unregister --config $config --all-runners
	if ($LASTEXITCODE -ne 0) {
		Write-Note "unregister failed; removing the local configuration anyway id=$runnerId"
	}
}
Remove-Item -LiteralPath $config -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $idFile -Force -ErrorAction SilentlyContinue
Write-Note "runner deleted reason=$reason id=$runnerId"
