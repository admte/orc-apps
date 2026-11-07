<#
.SYNOPSIS
Runs after the listener has exited; releases the runner only on a terminate.

.DESCRIPTION
On -StopReason:terminate it releases the registration (personal access token) or drops
this machine's runner identity files (a JSON registration); on any other reason it keeps
both.

.PARAMETER Url
Repository or organization URL (personal access token).

.PARAMETER TokenFile
File holding a personal access token or a runner registration as a JSON object.

.PARAMETER StopReason
Why the runner stopped (default exit).

.PARAMETER Attempts
Deregistration attempts (default 3).

.PARAMETER RetryInterval
Pause between attempts, in seconds (default 5).
#>
[CmdletBinding()]
param(
	[string]$Url = '',
	[string]$TokenFile = '',
	[string]$StopReason = 'exit',
	[string]$Attempts = '3',
	[string]$RetryInterval = '5'
)

$ErrorActionPreference = 'Stop'
# Windows PowerShell on Server 2016 offers only TLS 1.0 and 1.1 by default, and
# GitHub accepts nothing older than TLS 1.2.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Progress to stdout through Write-Host; warnings and errors to stderr.
function Write-Warn($message) {
	[Console]::Error.WriteLine("github-runner stopped: warning: $message")
}

# Runs after the listener has exited, so GitHub will not refuse the removal as
# busy. A registration made with a personal access token is released on stop
# reason `terminate` and on nothing else — a restart or a plain stop leaves this
# machine's runner in place, because the same install starts again against the
# same registration. A JSON registration carries no credential that could remove
# it, so only its identity files here are dropped.

if ($Attempts -notmatch '\A[0-9]+\z' -or [int]$Attempts -eq 0) {
	throw 'github-runner stopped: -Attempts must be a positive whole number'
}
if ($RetryInterval -notmatch '\A[0-9]+\z') {
	throw 'github-runner stopped: -RetryInterval must be a whole number of seconds'
}
$attemptCount = [int]$Attempts
$retrySeconds = [int]$RetryInterval

function Get-Token {
	if (-not $TokenFile) {
		throw 'github-runner stopped: -TokenFile is required'
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
		throw 'github-runner stopped: -Url must start with https://github.com/'
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

$reason = $StopReason
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

try { $credential = Get-Token } catch { $credential = '' }
if (-not $credential) {
	Write-Host "github-runner stopped: no credential available; nothing to deregister reason=$reason"
	exit 0
}

# A JSON registration comes with no credential that could remove the runner from
# GitHub, so that is left to whoever holds one. The identity files go, so an
# install that starts again registers fresh rather than running a removed
# identity — what `config.cmd remove` does on the PAT path.
if (Test-Minted $credential) {
	Write-Host "github-runner stopped: JSON registration; no credential here can remove it, nothing to deregister here reason=$reason"
	foreach ($file in '.runner', '.credentials', '.credentials_rsaparams') {
		Remove-Item -Force -LiteralPath (Join-Path $workDir $file) -ErrorAction SilentlyContinue
	}
	Write-Host "github-runner stopped: removed this machine's runner identity files dir=$workDir"
	exit 0
}

if (-not $Url) {
	throw 'github-runner stopped: -Url is required'
}
$headers = @{ Accept = 'application/vnd.github+json'; Authorization = "token $credential" }
$apiPath = Get-GitHubApiPath

Push-Location $workDir
try {
	for ($attempt = 1; $attempt -le $attemptCount; $attempt++) {
		Write-Host "github-runner stopped: deregistering the runner reason=$reason attempt=$attempt/$attemptCount"
		try {
			# A remove token is short-lived, so it is requested per attempt rather than
			# reused.
			$remove = Invoke-RestMethod -Method Post -Headers $headers `
				-Uri "https://api.github.com/$apiPath/actions/runners/remove-token"
			& .\config.cmd remove --token $remove.token
			if ($LASTEXITCODE -ne 0) {
				throw "config.cmd remove exited with $LASTEXITCODE"
			}
			Write-Host "github-runner stopped: runner deregistered reason=$reason"
			exit 0
		} catch {
			if ($attempt -ge $attemptCount) {
				throw "github-runner stopped: failed to deregister the runner after $attemptCount attempts: $_"
			}
			Write-Warn "deregistration attempt failed; retrying attempt=$attempt/$attemptCount error=$($_.Exception.Message)"
			Start-Sleep -Seconds $retrySeconds
		}
	}
} finally {
	Pop-Location
}
