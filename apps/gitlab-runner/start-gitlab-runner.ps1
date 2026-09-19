$ErrorActionPreference = 'Stop'

# Start phase: registration is node identity, so it happens here — once per node —
# and never in install, whose output a pool bake snapshots into a shared image.

function Get-TokenValue {
	if ($env:TOKEN_FILE) {
		return (Get-Content -LiteralPath $env:TOKEN_FILE -Raw).Trim()
	}
	if ($env:TOKEN) {
		return $env:TOKEN
	}
	throw 'gitlab-runner start: TOKEN_FILE or TOKEN is required'
}

$runner = Join-Path (Join-Path $env:ProgramFiles 'gitlab-runner') 'current\gitlab-runner.exe'
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
	throw "gitlab-runner start: no runner install found; install must run first path=$runner"
}

$workDir = Join-Path (Get-Location) 'gitlab-runner'
$builds = Join-Path $workDir 'builds'
New-Item -ItemType Directory -Path $builds -Force | Out-Null
$config = Join-Path $workDir 'config.toml'

# The runner's description in GitLab is the host name (a pool member is
# `<pool>-<slot>`), with the pool name appended so the whole pool is recognisable.
$runnerName = [System.Net.Dns]::GetHostName()
if ($env:POOL) {
	$runnerName = "$runnerName ($($env:POOL))"
}
$executor = if ($env:EXECUTOR) { $env:EXECUTOR } else { 'shell' }

# A `[[runners]]` section is what `register` writes, and it carries this node's
# runner manager identity. Present means an ordinary service restart, so the same
# identity is reused; absent means a fresh install, or the first boot of a clone
# whose baked image deliberately carries none.
$registered = (Test-Path -LiteralPath $config) -and
	(Select-String -LiteralPath $config -Pattern '^\[\[runners\]\]' -Quiet)
if ($registered) {
	Write-Host "gitlab-runner start: already registered; reusing this node's runner name=$runnerName"
} else {
	if (-not $env:URL) {
		throw 'gitlab-runner start: URL is required'
	}
	# The token goes through the environment, never a flag: a flag would show the
	# runner's credential in the process list to every job it later runs.
	Write-Host "gitlab-runner start: registering name=$runnerName executor=$executor url=$($env:URL)"
	$env:REGISTER_NON_INTERACTIVE = 'true'
	$env:CI_SERVER_URL = $env:URL
	$env:CI_SERVER_TOKEN = Get-TokenValue
	try {
		& $runner register --config $config --name $runnerName --executor $executor
		if ($LASTEXITCODE -ne 0) {
			throw "gitlab-runner start: registration failed name=$runnerName url=$($env:URL)"
		}
	} finally {
		Remove-Item Env:CI_SERVER_TOKEN -ErrorAction SilentlyContinue
	}
}

Write-Host "gitlab-runner start: starting the runner name=$runnerName config=$config"
& $runner run --config $config --working-directory $builds
exit $LASTEXITCODE
