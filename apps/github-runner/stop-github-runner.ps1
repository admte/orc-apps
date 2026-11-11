<#
.SYNOPSIS
Drains this machine's runner, then exits 0 with the listener still running.

.DESCRIPTION
With a personal access token, takes the labels off so no new job is routed here; in
either mode, waits for the job in flight to finish. Leaves the registration in place.

.PARAMETER Url
Repository or organization URL (personal access token).

.PARAMETER TokenFile
File holding a personal access token or a runner registration as a JSON object.

.PARAMETER Labels
Comma-separated labels to take off (personal access token).

.PARAMETER JobTimeout
Longest wait for the job in flight, in seconds (default 3540).

.PARAMETER PollInterval
How often to look for it, in seconds (default 10).
#>
[CmdletBinding()]
param(
	[string]$Url = '',
	[string]$TokenFile = '',
	[string]$Labels = '',
	# Just under an hour, so a stop that is given an hour ends with a message of its
	# own rather than being cut off mid-poll.
	[string]$JobTimeout = '3540',
	[string]$PollInterval = '10'
)

$ErrorActionPreference = 'Stop'
# Windows PowerShell on Server 2016 offers only TLS 1.0 and 1.1 by default, and
# GitHub accepts nothing older than TLS 1.2.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Progress to stdout through Write-Host; warnings and errors to stderr.
function Write-Warn($message) {
	[Console]::Error.WriteLine("github-runner stop: warning: $message")
}

# Runs before the listener is stopped, while it may still be mid-job. With a
# personal access token, take -Labels off the runner so the queue stops routing
# work here; in either mode, wait for the worker that is already running to finish,
# then exit 0. The listener is left running, to be stopped once this exits;
# deregistering is stopped-github-runner.ps1's, and only when the runner is going
# away for good.

if ($JobTimeout -notmatch '\A[0-9]+\z') {
	throw 'github-runner stop: -JobTimeout must be a whole number of seconds'
}
if ($PollInterval -notmatch '\A[0-9]+\z' -or [int]$PollInterval -eq 0) {
	throw 'github-runner stop: -PollInterval must be a positive whole number of seconds'
}
$jobTimeoutSeconds = [int]$JobTimeout
$pollSeconds = [int]$PollInterval

# Returns the comma-separated labels in $value with the space around each item
# trimmed and empty items dropped. GitHub refuses a label with a space in it or
# longer than 256 characters, so such a label stops here.
function Get-LabelList($value) {
	foreach ($item in $value.Split(',')) {
		$item = $item.Trim()
		if (-not $item) { continue }
		if ($item -match '[\s\p{Cc}]') {
			throw "github-runner stop: label '$item' contains a space or a control character"
		}
		if ($item.Length -gt 256) {
			throw "github-runner stop: label '$item' is longer than 256 characters"
		}
		$item
	}
}

$labelList = @(Get-LabelList $Labels)

function Get-Token {
	if (-not $TokenFile) {
		throw 'github-runner stop: -TokenFile is required'
	}
	return (Get-Content -Raw -LiteralPath $TokenFile).Trim()
}

# The token file holds either a personal access token or a runner registration
# supplied as a JSON object. They are told apart by shape: a value whose first
# non-blank character is `{` is the JSON registration.
function Test-Minted($value) {
	return [bool]($value -and $value.TrimStart().StartsWith('{'))
}

function Get-GitHubApiPath {
	if (-not $Url -or -not $Url.StartsWith('https://github.com/')) {
		throw 'github-runner stop: -Url must start with https://github.com/'
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

$record = Get-RegistrationRecord (Join-Path $workDir '.runner')
$runnerName = ''
# Names the runner in the lines below, or nothing when there is no record.
$who = ''
if ($record) {
	$runnerName = $record.name
	$who = " name=$runnerName"
	Write-Host "github-runner stop: found the runner in its registration record name=$runnerName id=$($record.id) file=$(Join-Path $workDir '.runner')"
}
# Absent is not fatal: without a credential there are no labels to take off, and
# the wait for the current job below still holds.
try { $credential = Get-Token } catch { $credential = '' }

# A JSON registration, a just-in-time one included, holds no API credential and
# set its labels when it registered, so there are no labels to take off: stopping
# the service once the job below has finished is what keeps the listener from
# taking another. A directory with no readable `.runner` was never registered, or
# no longer is, so there is no runner whose labels could be taken off.
if (-not $credential) {
	Write-Host "github-runner stop: no credential available; skipping the label step$who"
} elseif (Test-Minted $credential) {
	Write-Host "github-runner stop: JSON registration; no labels to remove, relying on the service stop$who"
} elseif ($labelList.Count -eq 0) {
	Write-Host "github-runner stop: no labels to remove; relying on the service stop$who"
} elseif (-not $record) {
	Write-Host "github-runner stop: no registration record; no runner to unlabel file=$(Join-Path $workDir '.runner')"
} else {
	if (-not $Url) {
		throw 'github-runner stop: -Url is required'
	}
	$headers = @{ Accept = 'application/vnd.github+json'; Authorization = "token $credential" }
	$apiPath = Get-GitHubApiPath
	$runnerId = $record.id
	Write-Host "github-runner stop: removing the labels so no new job is routed here name=$runnerName id=$runnerId labels=$($labelList -join ',')"
	# One request per label; a failure is logged and the rest still go. A label goes
	# into the request path, so it is percent-encoded there: a slash, a question mark
	# or a hash in it would otherwise change the URL.
	foreach ($label in $labelList) {
		try {
			Invoke-RestMethod -Method Delete -Headers $headers `
				-Uri "https://api.github.com/$apiPath/actions/runners/$runnerId/labels/$([uri]::EscapeDataString($label))" | Out-Null
		} catch {
			Write-Warn "label removal failed; continuing to wait for the current job name=$runnerName label=$label"
		}
	}
}

if (-not (Test-WorkerRunning $workDir)) {
	Write-Host "github-runner stop: no job in flight; safe to stop$who"
	exit 0
}

Write-Host "github-runner stop: waiting for the current job to finish$who timeout=${jobTimeoutSeconds}s"
$waited = 0
while (Test-WorkerRunning $workDir) {
	if ($waited -ge $jobTimeoutSeconds) {
		throw "github-runner stop: job was still running after ${jobTimeoutSeconds}s$who"
	}
	Start-Sleep -Seconds $pollSeconds
	$waited += $pollSeconds
}

Write-Host "github-runner stop: job finished; safe to stop$who waited=${waited}s"
