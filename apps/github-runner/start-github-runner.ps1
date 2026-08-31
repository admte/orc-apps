$ErrorActionPreference = 'Stop'

# Start phase: registration is node identity, so it happens here — once per node,
# every time a node that has none comes up — and never in install. A pool bake
# runs the install phase alone and snapshots the disk, so a registration made
# there would belong to a builder that is destroyed straight afterwards, and
# `config.cmd` writes `.runner` and `.credentials` — the runner's own auth
# material — into an image every clone shares. Install leaves the runner
# unconfigured; this script gives the running node its own identity, then runs
# the listener.

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
# pages until one comes back short or the name is found. Same shape as
# stop-github-runner.ps1, which looks the runner up to take the label off.
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

$workDir = 'github-runner'
if (-not (Test-Path (Join-Path $workDir 'config.cmd'))) {
	throw "github-runner start: no runner install found; install must run first dir=$workDir"
}
$workDir = (Resolve-Path $workDir).Path
Set-Location $workDir

# Runner name is the host name; its label is the pool name (pool.name x-source -> POOL).
$runnerName = $env:COMPUTERNAME
$labels = if ($env:POOL) { $env:POOL } else { '' }

# `.runner` is the file config.cmd writes when a directory has been configured; it
# and the `.credentials` beside it are this node's identity. Absent means the node
# has none yet — a fresh install, or the first boot of a clone whose baked image
# carried the unpacked runner but deliberately no identity — so register. Present
# means an ordinary service restart, and config.cmd refuses an already-configured
# directory, so registration is skipped and the same identity is reused. The
# stopped hook's `config.cmd remove` deletes `.runner`, which is what makes a
# terminated-then-restarted install register again rather than start unconfigured.
if (Test-Path (Join-Path $workDir '.runner')) {
	Write-Host "github-runner start: already registered; reusing this node's identity name=$runnerName dir=$workDir"
} else {
	# A registration token is short-lived, so it is minted at the moment it is
	# used and never persisted.
	$registration = Invoke-RestMethod -Method Post `
		-Headers @{ Accept = 'application/vnd.github+json'; Authorization = "token $(Get-Token)" } `
		-Uri "https://api.github.com/$(Get-GitHubApiPath)/actions/runners/registration-token"
	if (-not $registration.token) {
		throw 'github-runner start: failed to create registration token'
	}

	$configArgs = @('--name', $runnerName, '--url', $env:URL, '--token', $registration.token, '--unattended', '--replace')
	if ($labels) {
		$configArgs += @('--labels', $labels)
	}

	Write-Host "github-runner start: registering name=$runnerName labels=$labels"
	& .\config.cmd @configArgs
	if ($LASTEXITCODE -ne 0) {
		throw "github-runner start: config.cmd failed with exit code $LASTEXITCODE"
	}
}

# Puts the pool label back. stop-github-runner.ps1 takes it off through the API so
# the queue stops routing work here during a drain, and the registration itself
# outlives every stop reason but `terminate` — so a drained node would otherwise
# come back online carrying only its default labels, and `runs-on: <pool>` would
# never match it again: healthy-looking, and silently never given another job.
# POST .../labels adds without replacing, so this runs on both paths above,
# whether config.cmd just passed --labels or the registration was already there.
# It is never fatal: a runner with no label still beats a node that will not start.
if (-not $labels) {
	Write-Host "github-runner start: no pool label to ensure name=$runnerName"
} else {
	try {
		$labelHeaders = @{ Accept = 'application/vnd.github+json'; Authorization = "token $(Get-Token)" }
		$labelApiPath = Get-GitHubApiPath
		$runnerId = Find-RunnerId $labelApiPath $labelHeaders $runnerName
		if (-not $runnerId) {
			throw "runner is not registered name=$runnerName"
		}
		# Built from ConvertTo-Json on the label itself, so a quote or a backslash
		# in it cannot break the body.
		$body = '{"labels":[' + ($labels | ConvertTo-Json -Compress) + ']}'
		Invoke-RestMethod -Method Post -Headers $labelHeaders -ContentType 'application/json' `
			-Body $body -Uri "https://api.github.com/$labelApiPath/actions/runners/$runnerId/labels" | Out-Null
		Write-Host "github-runner start: pool label ensured name=$runnerName id=$runnerId label=$labels"
	} catch {
		Write-Host "github-runner start: could not ensure the pool label; starting without it name=$runnerName label=$labels error=$($_.Exception.Message)"
	}
}

# The listener runs as the account the runtime runs as; there is no unprivileged-user
# rule to satisfy on Windows.
Write-Host "github-runner start: starting the listener name=$runnerName dir=$workDir"
& .\run.cmd
exit $LASTEXITCODE
