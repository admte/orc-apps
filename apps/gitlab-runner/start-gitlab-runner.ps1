$ErrorActionPreference = 'Stop'

# Start phase: the runner is node identity, so it is created here — once per node —
# and never in install, whose output a pool bake snapshots into a shared image.

$FormType = 'application/x-www-form-urlencoded'

function Get-TokenValue {
	if ($env:TOKEN_FILE) {
		return (Get-Content -Raw -LiteralPath $env:TOKEN_FILE).Trim()
	}
	if ($env:TOKEN) {
		return $env:TOKEN.Trim()
	}
	throw 'gitlab-runner start: TOKEN_FILE or TOKEN is required'
}

function Get-GitLabUri {
	if (-not $env:URL -or -not $env:URL.StartsWith('https://')) {
		throw 'gitlab-runner start: URL must start with https://'
	}
	return [uri]$env:URL
}

# The runner scope for the configured URL: the namespace after the host is a
# project or a group, and an empty one is the instance itself.
function Resolve-Target($api, $headers, $uri) {
	# AbsolutePath is already percent-encoded; decoding first keeps a path that
	# contains an encoded character from being escaped twice.
	$namespace = [uri]::UnescapeDataString($uri.AbsolutePath).Trim('/')
	if ($namespace.EndsWith('.git')) {
		$namespace = $namespace.Substring(0, $namespace.Length - 4)
	}
	if (-not $namespace) {
		return @{ runner_type = 'instance_type' }
	}
	$encoded = [uri]::EscapeDataString($namespace)
	foreach ($kind in @(
			@{ path = 'projects'; type = 'project_type'; field = 'project_id' },
			@{ path = 'groups'; type = 'group_type'; field = 'group_id' })) {
		try {
			$found = Invoke-RestMethod -Headers $headers -Uri "$api/$($kind.path)/$encoded"
			if ($found.id) {
				return @{ runner_type = $kind.type; field = $kind.field; id = $found.id }
			}
		} catch {
			continue
		}
	}
	throw "gitlab-runner start: no project or group at $namespace, or the token cannot see it"
}

# By path, not through PATH, and by the version this app instance was installed
# as: `current` belongs to whichever version was installed last, which on a node
# carrying two of them is somebody else's.
$root = Join-Path $env:ProgramFiles 'gitlab-runner'
$runner = Join-Path (Join-Path $root $env:APP_VERSION) 'gitlab-runner.exe'
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
	$runner = Join-Path (Join-Path $root 'current') 'gitlab-runner.exe'
}
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
	throw "gitlab-runner start: no runner install found; install must run first path=$runner"
}

$workDir = Join-Path (Get-Location) 'gitlab-runner'
$builds = Join-Path $workDir 'builds'
New-Item -ItemType Directory -Path $builds -Force | Out-Null
$config = Join-Path $workDir 'config.toml'
$idFile = Join-Path $workDir 'runner.id'

$uri = Get-GitLabUri
$base = "$($uri.Scheme)://$($uri.Authority)"
$api = "$base/api/v4"
$headers = @{ 'PRIVATE-TOKEN' = Get-TokenValue }

# The description is the host name (a pool member is `<pool>-<slot>`), the tag is
# the pool name, so `tags: [<pool>]` routes to this pool. Without a pool name
# there is nothing to route on, so the runner takes untagged jobs instead.
$runnerName = [System.Net.Dns]::GetHostName()
$tags = $env:POOL
$executor = if ($env:EXECUTOR) { $env:EXECUTOR } else { 'shell' }

$registered = (Test-Path -LiteralPath $config) -and
	(Select-String -LiteralPath $config -Pattern '^\[\[runners\]\]' -Quiet)
if ($registered) {
	Write-Host "gitlab-runner start: already registered; reusing this node's runner name=$runnerName"
	# Puts the runner back into rotation: stop pauses it through the API, and the
	# runner outlives every stop reason but terminate, so a drained node would
	# otherwise come back online paused — healthy-looking and never given a job.
	# Never fatal: a runner to resume by hand beats a node that will not start.
	try {
		$runnerId = if (Test-Path -LiteralPath $idFile) { (Get-Content -Raw -LiteralPath $idFile) } else { $null }
		if ($runnerId) {
			$runnerId = $runnerId.Trim()
		}
		if ($runnerId) {
			# PowerShell only applies the form content type to POST, so a PUT whose
			# type is left out arrives with no body GitLab will parse.
			Invoke-RestMethod -Method Put -Headers $headers -ContentType $FormType `
				-Body @{ paused = 'false' } -Uri "$api/runners/$runnerId" | Out-Null
			Write-Host "gitlab-runner start: runner resumed id=$runnerId"
		} else {
			Write-Host 'gitlab-runner start: no runner id recorded; nothing to resume'
		}
	} catch {
		Write-Host "gitlab-runner start: could not resume the runner; starting anyway error=$($_.Exception.Message)"
	}
} else {
	$target = Resolve-Target $api $headers $uri
	$body = @{ runner_type = $target.runner_type; description = $runnerName }
	if ($target.field) { $body[$target.field] = $target.id }
	if ($tags) { $body['tag_list'] = $tags } else { $body['run_untagged'] = 'true' }

	Write-Host "gitlab-runner start: creating the runner name=$runnerName type=$($target.runner_type) tags=$tags"
	$created = Invoke-RestMethod -Method Post -Headers $headers -ContentType $FormType `
		-Body $body -Uri "$api/user/runners"
	if (-not $created.id -or -not $created.token) {
		throw "gitlab-runner start: GitLab returned no runner token name=$runnerName"
	}

	# The id is what stop and stopped use to pause and delete this runner; the
	# token cannot be read back, so config.toml is its only other copy.
	Set-Content -LiteralPath $idFile -Value $created.id -NoNewline

	# The token goes through the environment, never a flag: a flag would show the
	# runner's credential in the process list to every job it later runs.
	$env:REGISTER_NON_INTERACTIVE = 'true'
	$env:CI_SERVER_URL = $base
	$env:CI_SERVER_TOKEN = $created.token
	try {
		& $runner register --config $config --name $runnerName --executor $executor
		$registerExit = $LASTEXITCODE
	} finally {
		Remove-Item Env:CI_SERVER_TOKEN -ErrorAction SilentlyContinue
		Remove-Item Env:CI_SERVER_URL -ErrorAction SilentlyContinue
		Remove-Item Env:REGISTER_NON_INTERACTIVE -ErrorAction SilentlyContinue
	}
	if ($registerExit -ne 0) {
		# The runner exists in GitLab but this node cannot use it. Left behind it
		# would be orphaned there, and the next start attempt would create another:
		# a crash loop would fill the runners list.
		try {
			Invoke-RestMethod -Method Delete -Headers $headers -Uri "$api/runners/$($created.id)" | Out-Null
		} catch {
			Write-Host "gitlab-runner start: could not delete the runner after a failed registration id=$($created.id)"
		}
		Remove-Item -LiteralPath $idFile -Force -ErrorAction SilentlyContinue
		throw "gitlab-runner start: registration failed name=$runnerName id=$($created.id)"
	}
	Write-Host "gitlab-runner start: runner created and registered name=$runnerName id=$($created.id)"
}

Write-Host "gitlab-runner start: starting the runner name=$runnerName config=$config"
& $runner run --config $config --working-directory $builds
exit $LASTEXITCODE
