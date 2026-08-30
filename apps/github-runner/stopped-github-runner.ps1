$ErrorActionPreference = 'Stop'

# Post-exit hook: the listener is already gone, so GitHub will not refuse the
# removal as busy. The registration is released on APP_STOP_REASON=terminate and
# on nothing else — a restart or a plain stop leaves this node's runner in place,
# because the same install starts again against the same registration.

$attempts = if ($env:ATTEMPTS) { [int]$env:ATTEMPTS } else { 3 }
$retryInterval = if ($env:RETRY_INTERVAL) { [int]$env:RETRY_INTERVAL } else { 5 }

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

$reason = if ($env:APP_STOP_REASON) { $env:APP_STOP_REASON } else { 'exit' }
if ($reason -ne 'terminate') {
	Write-Host "github-runner stopped: keeping the runner registration reason=$reason"
	exit 0
}

$workDir = 'github-runner'
if (-not (Test-Path (Join-Path $workDir 'config.cmd'))) {
	Write-Host "github-runner stopped: no install found; nothing to deregister dir=$workDir"
	exit 0
}
$workDir = (Resolve-Path $workDir).Path

$headers = @{ Accept = 'application/vnd.github+json'; Authorization = "token $(Get-Token)" }
$apiPath = Get-GitHubApiPath

Push-Location $workDir
try {
	for ($attempt = 1; $attempt -le $attempts; $attempt++) {
		Write-Host "github-runner stopped: deregistering the runner reason=$reason attempt=$attempt/$attempts"
		try {
			# A remove token is short-lived, so it is minted per attempt rather than reused.
			$remove = Invoke-RestMethod -Method Post -Headers $headers `
				-Uri "https://api.github.com/$apiPath/actions/runners/remove-token"
			& .\config.cmd remove --token $remove.token
			if ($LASTEXITCODE -ne 0) {
				throw "config.cmd remove exited with $LASTEXITCODE"
			}
			Write-Host "github-runner stopped: runner deregistered reason=$reason"
			exit 0
		} catch {
			if ($attempt -ge $attempts) {
				throw "github-runner stopped: failed to deregister the runner after $attempts attempts: $_"
			}
			Write-Host "github-runner stopped: deregistration attempt failed; retrying attempt=$attempt/$attempts"
			Start-Sleep -Seconds $retryInterval
		}
	}
} finally {
	Pop-Location
}
