<#
.SYNOPSIS
Registers this machine's runner if it has no identity yet, then runs the listener.

.DESCRIPTION
Run from the directory install ran in. A personal access token registers under the host
name with -Labels; a runner registration supplied as a JSON object carries its own url,
name and labels.

.PARAMETER Url
Repository or organization URL; used with a personal access token, ignored for a
JSON registration.

.PARAMETER TokenFile
File holding a personal access token or a runner registration as a JSON object; optional
when the runner is already registered.

.PARAMETER Labels
Comma-separated labels the runner carries with a personal access token.

.PARAMETER Ephemeral
true: take one job, then exit (default: false). A just-in-time registration needs true,
a persistent JSON registration false, a personal access token either.
#>
[CmdletBinding()]
param(
	[string]$Url = '',
	[string]$TokenFile = '',
	[string]$Labels = '',
	[string]$Ephemeral = 'false'
)

$ErrorActionPreference = 'Stop'
# Windows PowerShell on Server 2016 offers only TLS 1.0 and 1.1 by default, and
# GitHub accepts nothing older than TLS 1.2.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Progress to stdout through Write-Host; warnings and errors to stderr.
function Write-Warn($message) {
	[Console]::Error.WriteLine("github-runner start: warning: $message")
}

# Registration gives a machine its own runner identity, so it happens here — the
# first time the runner starts on a machine that has none — and never in install:
# an installed disk may be imaged and copied, and `config.cmd` writes `.runner`
# and `.credentials` — the runner's own auth material — that every copy would
# share. Install leaves the runner unconfigured; this script registers it, then
# runs the listener.

# Returns the comma-separated labels in $value with the space around each item
# trimmed and empty items dropped. GitHub refuses a label with a space in it or
# longer than 256 characters, so such a label stops here.
function Get-LabelList($value) {
	foreach ($item in $value.Split(',')) {
		$item = $item.Trim()
		if (-not $item) { continue }
		if ($item -match '[\s\p{Cc}]') {
			throw "github-runner start: label '$item' contains a space or a control character"
		}
		if ($item.Length -gt 256) {
			throw "github-runner start: label '$item' is longer than 256 characters"
		}
		$item
	}
}

$labelList = @(Get-LabelList $Labels)

if (-not $Ephemeral) { $Ephemeral = 'false' }
if ($Ephemeral -notin 'true', 'false') {
	throw 'github-runner start: -Ephemeral must be true or false'
}
$isEphemeral = $Ephemeral -eq 'true'

function Get-Token {
	if (-not $TokenFile) {
		throw 'github-runner start: -TokenFile is required'
	}
	return (Get-Content -Raw -LiteralPath $TokenFile).Trim()
}

# The token file holds either a personal access token or a runner registration
# supplied as a JSON object. They are told apart by shape: a value whose first
# non-blank character is `{` is the JSON registration.
function Test-Minted($value) {
	return [bool]($value -and $value.TrimStart().StartsWith('{'))
}

# Reads a JSON registration and returns it. Three modes are understood:
# `persistent`, a repository runner; `persistent-org`, an organization runner; and
# `jit`, a just-in-time runner configuration that takes one job. Any other mode
# stops here with a fixed message, so a registration meant for a scope this
# version does not know is never registered as something else.
function Read-Registration($value) {
	try {
		$cred = $value | ConvertFrom-Json
	} catch {
		throw "github-runner start: the registration is not valid JSON: $($_.Exception.Message)"
	}
	if ($cred.mode -cnotin 'persistent', 'persistent-org', 'jit') {
		throw "github-runner: credential mode $($cred.mode) is not supported by this version"
	}
	return $cred
}

# Returns a `jit` registration's runner name and encoded runner configuration. The
# configuration is checked to be base64, so it is one line with nothing in it cmd.exe
# or the runner could read as anything else.
function Get-JitRegistration($cred) {
	foreach ($key in 'name', 'jitconfig') {
		if (-not ($cred.$key -is [string]) -or -not $cred.$key) {
			throw "github-runner start: the just-in-time registration has no $key"
		}
	}
	if ($cred.name -match '[\r\n]') {
		throw 'github-runner start: the just-in-time registration name contains a line break'
	}
	if ($cred.jitconfig -cnotmatch '\A[A-Za-z0-9+/]+={0,2}\z') {
		throw 'github-runner start: the just-in-time registration jitconfig is not base64'
	}
	return [pscustomobject]@{
		name      = $cred.name
		jitconfig = $cred.jitconfig
	}
}

# Returns a persistent registration's url, token, name and labels (joined by
# commas). `persistent` is a repository runner; `persistent-org` an organization
# runner whose url is `https://<host>[:port]/<org>` — github.com or an Enterprise
# Server's own address. Labels are required: the runner registers with them alone,
# without GitHub's default labels.
function Get-MintedRegistration($cred) {
	foreach ($key in 'url', 'token', 'name') {
		if (-not ($cred.$key -is [string]) -or -not $cred.$key) {
			throw "github-runner start: the JSON registration has no $key"
		}
	}
	$labels = @()
	if ($null -ne $cred.labels) {
		if (-not ($cred.labels -is [array])) {
			throw 'github-runner start: the JSON registration labels must be a list of names without commas'
		}
		foreach ($label in @($cred.labels)) {
			if (-not ($label -is [string]) -or -not $label -or $label.Contains(',')) {
				throw 'github-runner start: the JSON registration labels must be a list of names without commas'
			}
			$labels += $label
		}
	}
	# https, a host with an optional port, then exactly one path segment (the org) and
	# at most one trailing slash; no query or fragment. The same pattern as the sh.
	if ($cred.mode -ceq 'persistent-org' -and
		$cred.url -cnotmatch '\Ahttps://[A-Za-z0-9.-]+(:[0-9]+)?/[^/?#]+/?\z') {
		throw 'github-runner start: a persistent-org credential url must be https://<host>/<org>'
	}
	if ($labels.Count -eq 0) {
		throw 'github-runner start: the JSON registration has no labels'
	}
	return [pscustomobject]@{
		url    = $cred.url
		token  = $cred.token
		name   = $cred.name
		labels = $labels -join ','
	}
}

function Get-GitHubApiPath {
	if (-not $Url -or -not $Url.StartsWith('https://github.com/')) {
		throw 'github-runner start: -Url must start with https://github.com/'
	}
	$path = $Url.Substring('https://github.com/'.Length).TrimEnd('/')
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

# Returns the id and the name this directory's runner registered under, from
# `.runner`: the record config.cmd writes when it registers, with a UTF-8 BOM.
# Returns nothing when the record is missing or unreadable, so the runner is found
# by its own registration, never by a name guessed here.
function Get-RegistrationRecord($runnerFile) {
	try {
		$text = [System.IO.File]::ReadAllText($runnerFile).TrimStart([char]0xFEFF)
		$record = $text | ConvertFrom-Json
	} catch {
		return $null
	}
	$id = $record.agentId
	if (-not ($id -is [int] -or $id -is [long]) -or $id -le 0) {
		return $null
	}
	return [pscustomobject]@{
		id   = $id
		name = [string]$record.agentName
	}
}

# Runs the listener until it ends for good and leaves how it ended in
# $script:listenerExit.
#
# The runner's own run.cmd relaunches the listener the same way, but it exits 0
# for every end it does not relaunch on, so a listener that crashed, failed or was
# ended by another process would read as one that finished. The rules here are
# run.cmd's, with every such end passed on:
#
#   0     finished, including after a stop or a one-job runner's job
#   2     retryable error: relaunch after 5 seconds
#   3, 4  self-update: relaunch once the update has written update.finished, or
#         after about 30 seconds
#   other that code (1 is an error, 5 a session conflict)
#
# A just-in-time listener writes its identity files from its configuration each
# time it starts, as hidden files it cannot overwrite, so -Jit removes those an
# earlier launch wrote before each one.
#
# The listener runs on this script's console, so the stop's Ctrl+C reaches it
# directly; it finishes its job and exits, and PowerShell, stopped by the same
# Ctrl+C, relaunches nothing. Call this bare, never as `$x = Invoke-Listener`:
# that would capture the listener's output along with the function's.
function Invoke-Listener([switch]$Jit) {
	$listener = Join-Path $workDir 'bin\Runner.Listener.exe'
	$updateFile = Join-Path $workDir 'update.finished'
	while ($true) {
		if ($Jit) {
			foreach ($file in '.runner', '.credentials', '.credentials_rsaparams') {
				Remove-Item -Force -LiteralPath (Join-Path $workDir $file) -ErrorAction SilentlyContinue
			}
		}
		& $listener run
		$code = $LASTEXITCODE
		if ($code -eq 0) {
			Write-Host 'github-runner start: the listener finished'
			break
		} elseif ($code -eq 2) {
			Write-Host 'github-runner start: the listener ended with a retryable error; relaunching in 5 seconds'
			Start-Sleep -Seconds 5
		} elseif ($code -eq 3 -or $code -eq 4) {
			Write-Host 'github-runner start: the listener ended to update itself; relaunching once the update is in place'
			for ($i = 0; $i -lt 30; $i++) {
				if (Test-Path -LiteralPath $updateFile) {
					Write-Host 'github-runner start: the update finished'
					Remove-Item -Force -LiteralPath $updateFile -ErrorAction SilentlyContinue
					break
				}
				Start-Sleep -Seconds 1
			}
		} else {
			Write-Warn "the listener ended with an error exit_code=$code"
			break
		}
	}
	$script:listenerExit = $code
}

$workDir = 'github-runner'
if (-not (Test-Path (Join-Path $workDir 'config.cmd'))) {
	throw "github-runner start: no runner install found; install must run first dir=$workDir"
}
$workDir = (Resolve-Path $workDir).Path
Set-Location $workDir

# Runner name is the host name; its labels are -Labels, parsed above.
$runnerName = $env:COMPUTERNAME
$runnerLabels = $labelList -join ','

# `.runner` is the file config.cmd writes when a directory has been configured; it
# and the `.credentials` beside it are this machine's identity. Absent means the
# machine has none yet — a fresh install, or the first start on a copy of an
# installed disk, which carries the unpacked runner but deliberately no identity —
# so register. Present means an ordinary service restart, and config.cmd refuses an
# already-configured directory, so registration is skipped and the same identity
# is reused. With a personal access token, stopped-github-runner.ps1's
# `config.cmd remove` deletes `.runner`, which is what makes a
# terminated-then-restarted install register again rather than start
# unconfigured.
#
# A JSON registration carries its own url — a repository or, in the
# persistent-org mode, an organization — runner name and labels, and the token in
# it is already a registration token, so it goes to config.cmd as is; -Url, the
# host name and -Labels are not used for it. An absent token is not fatal here: a
# runner with `.runner` starts without one, and the PAT registration below fails
# on it by name.
try { $credential = Get-Token } catch { $credential = '' }
$minted = Test-Minted $credential
$mode = 'token'
$readError = $null
# Read leniently here: a registration that cannot be read only matters when it is
# about to be used. A runner with `.runner` restarts without it; the registration
# below stops with the reason.
if ($minted) {
	try {
		$cred = Read-Registration $credential
		$mode = $cred.mode
	} catch {
		$readError = $_
		$mode = 'unreadable'
	}
}

# -Ephemeral must agree with the credential. A just-in-time registration is
# ephemeral by construction, and a persistent JSON registration cannot be made
# ephemeral here, so either mismatch stops before anything is registered. A
# personal access token registers whichever way -Ephemeral says.
if ($mode -ceq 'jit' -and -not $isEphemeral) {
	throw 'github-runner start: a just-in-time registration takes one job and exits; start it with -Ephemeral:true'
}
if (($mode -cin 'persistent', 'persistent-org') -and $isEphemeral) {
	throw "github-runner start: a $mode registration is not ephemeral; start it with -Ephemeral:false, or supply a just-in-time registration"
}

# A just-in-time registration is the runner's whole configuration: the listener
# starts from it with no config.cmd, takes one job and exits. It is never reused, so a `.runner` an earlier start
# left behind does not make it "already registered"; its labels are part of the
# configuration, so there is no label upkeep. Invoke-Listener removes the identity
# files an earlier launch wrote before each one. The listener exits 0 after its
# job, which ends this script, so it never takes a second one.
#
# The configuration reaches the listener as ACTIONS_RUNNER_INPUT_JITCONFIG, which
# the runner reads exactly as it reads `--jitconfig`, and then clears from
# its own environment. Never on a command line: a process's arguments are visible
# to every user of the machine, its environment only to its own account and
# administrators. It is set in this process only, for the listener to inherit, and
# is not logged.
if ($mode -ceq 'jit') {
	$jit = Get-JitRegistration $cred
	Write-Host "github-runner start: starting the just-in-time listener name=$($jit.name) dir=$workDir"
	$env:ACTIONS_RUNNER_INPUT_JITCONFIG = $jit.jitconfig
	try {
		Invoke-Listener -Jit
	} finally {
		Remove-Item -LiteralPath Env:ACTIONS_RUNNER_INPUT_JITCONFIG -ErrorAction SilentlyContinue
	}
	exit $script:listenerExit
}

if (Test-Path (Join-Path $workDir '.runner')) {
	$record = Get-RegistrationRecord (Join-Path $workDir '.runner')
	if ($record -and $record.name) { $runnerName = $record.name }
	Write-Host "github-runner start: already registered; reusing this machine's identity name=$runnerName dir=$workDir"
} elseif ($minted) {
	if ($readError) { throw $readError }
	$registration = Get-MintedRegistration $cred
	$runnerName = $registration.name
	$runnerLabels = $registration.labels

	# Only the registration's labels, none of GitHub's defaults: a job elsewhere in
	# the repository or organization that asks for `self-hosted`, an OS or an
	# architecture must not land on a runner meant only for these labels.
	$configArgs = @('--unattended', '--url', $registration.url, '--token', $registration.token, '--name', $runnerName,
		'--no-default-labels', '--labels', $runnerLabels, '--replace')

	Write-Host "github-runner start: registering with the JSON registration name=$runnerName labels=$runnerLabels"
	& .\config.cmd @configArgs
	if ($LASTEXITCODE -ne 0) {
		throw "github-runner start: config.cmd failed with exit code $LASTEXITCODE"
	}
} else {
	if (-not $Url) {
		throw 'github-runner start: -Url is required'
	}
	# A registration token is short-lived, so it is requested at the moment it is
	# used and never persisted.
	$registration = Invoke-RestMethod -Method Post `
		-Headers @{ Accept = 'application/vnd.github+json'; Authorization = "token $(Get-Token)" } `
		-Uri "https://api.github.com/$(Get-GitHubApiPath)/actions/runners/registration-token"
	if (-not $registration.token) {
		throw 'github-runner start: failed to create registration token'
	}

	$configArgs = @('--name', $runnerName, '--url', $Url, '--token', $registration.token, '--unattended', '--replace')
	if ($runnerLabels) {
		$configArgs += @('--labels', $runnerLabels)
	}
	# An ephemeral runner takes one job, then GitHub removes it and the listener
	# exits.
	if ($isEphemeral) {
		$configArgs += '--ephemeral'
	}

	Write-Host "github-runner start: registering name=$runnerName labels=$runnerLabels ephemeral=$Ephemeral"
	& .\config.cmd @configArgs
	if ($LASTEXITCODE -ne 0) {
		throw "github-runner start: config.cmd failed with exit code $LASTEXITCODE"
	}
}

# Puts the labels back. stop-github-runner.ps1 takes them off through the API so
# the queue stops routing work here during a drain, and the registration itself
# outlives every stop reason but `terminate` — so a drained runner would otherwise
# come back online carrying only its default labels, and `runs-on: <label>` would
# never match it again: healthy-looking, and silently never given another job.
# POST .../labels adds without replacing, so this runs on both PAT paths above,
# whether config.cmd just passed --labels or the registration was already there.
# It is never fatal: a runner with no labels still beats one that will not start.
# A JSON registration set its labels at registration and holds no API
# credential, so there is nothing to restore: stop leaves them alone too.
if ($minted) {
	Write-Host "github-runner start: labels were set at registration; no label upkeep name=$runnerName"
} elseif ($labelList.Count -eq 0) {
	Write-Host "github-runner start: no labels to ensure name=$runnerName"
} else {
	try {
		$labelHeaders = @{ Accept = 'application/vnd.github+json'; Authorization = "token $(Get-Token)" }
		$labelApiPath = Get-GitHubApiPath
		$runnerId = Find-RunnerId $labelApiPath $labelHeaders $runnerName
		if (-not $runnerId) {
			throw "runner is not registered name=$runnerName"
		}
		# Every label in one body, each built from ConvertTo-Json on the label
		# itself, so a quote or a backslash in it cannot break the body.
		$body = '{"labels":[' + (($labelList | ForEach-Object { ConvertTo-Json -InputObject $_ -Compress }) -join ',') + ']}'
		Invoke-RestMethod -Method Post -Headers $labelHeaders -ContentType 'application/json' `
			-Body $body -Uri "https://api.github.com/$labelApiPath/actions/runners/$runnerId/labels" | Out-Null
		Write-Host "github-runner start: labels ensured name=$runnerName id=$runnerId labels=$runnerLabels"
	} catch {
		Write-Warn "could not ensure the labels; starting without them name=$runnerName labels=$runnerLabels error=$($_.Exception.Message)"
	}
}

# The listener runs as the account that runs this script; there is no
# unprivileged-user rule to satisfy on Windows.
Write-Host "github-runner start: starting the listener name=$runnerName dir=$workDir"
# The listener finishes and exits on Ctrl+C, the way a Windows service stops it.
# It runs directly, not through run.cmd: cmd.exe answers Ctrl+C in a batch file
# with "Terminate batch job (Y/N)?", and run.cmd turns every listener end it does
# not relaunch on into exit 0.
Invoke-Listener
exit $script:listenerExit
