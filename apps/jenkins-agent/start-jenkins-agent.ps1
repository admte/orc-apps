<#
.SYNOPSIS
Runs the Jenkins Swarm client in the foreground, named after this machine.

.DESCRIPTION
Run after install. The client runs as the account that runs this script.

.PARAMETER Url
Jenkins controller URL.

.PARAMETER Username
Jenkins user the agent connects as.

.PARAMETER Labels
Space-separated labels for the agent.

.PARAMETER TlsCaFile
File holding extra CA certificates (PEM) to verify the controller with, trusted
alongside the system CAs.

.PARAMETER AgentDir
The agent's own directory. Default: C:\ProgramData\jenkins-agent.

.PARAMETER RunnerDir
Where install copied the runner. Default: the bin directory under -AgentDir.
#>
[CmdletBinding()]
param(
	[string]$Url = '',
	[string]$Username = '',
	[string]$Labels = '',
	[string]$TlsCaFile = '',
	[string]$AgentDir = 'C:\ProgramData\jenkins-agent',
	[string]$RunnerDir = ''
)

$ErrorActionPreference = 'Stop'

# Runs the Swarm client in the foreground, for a service manager to supervise: this
# script is meant to be a service's main process. The package registers nothing with
# the SCM.
#
# There is no privilege drop: Windows has no setpriv and the app carries no service
# account of its own, so the Swarm client runs as the account that runs this script.

if (-not $Url) { throw 'jenkins-agent start: -Url is required' }
if (-not $Username) { throw 'jenkins-agent start: -Username is required' }

if (-not $RunnerDir) { $RunnerDir = Join-Path $AgentDir 'bin' }
$runnerPath = Join-Path $RunnerDir 'jenkins-agent.ps1'
# Where the supplied CA chain is staged for the runner and for stop-jenkins-agent.ps1.
$caPath = Join-Path $AgentDir 'platform-ca.pem'

# Copies the CA chain in -TlsCaFile to a fixed path beside the rest of the agent's
# state. That file may be gone once the start is over, and stop-jenkins-agent.ps1
# runs on its own, so it needs a copy that stays.
#
# Copied on every start, never at install: a private CA's certificates may be
# short-lived and renewed by restarting the service, and a chain copied at install
# would go stale. When nothing is supplied the stale copy is removed, so a
# controller that moved to a publicly issued certificate is not left verifying
# against yesterday's chain.
function Copy-PlatformCaBundle($caPath) {
	if ($TlsCaFile -and (Test-Path -LiteralPath $TlsCaFile -PathType Leaf) -and
		(Get-Item -LiteralPath $TlsCaFile).Length -gt 0) {
		Copy-Item -LiteralPath $TlsCaFile -Destination $caPath -Force
		Write-Host "jenkins-agent start: staged the supplied CA bundle path=$caPath"
		return
	}
	Remove-Item -Force -LiteralPath $caPath -ErrorAction SilentlyContinue
	Write-Host 'jenkins-agent start: no CA bundle supplied; using the OS trust store'
}

if (-not (Test-Path -LiteralPath $runnerPath -PathType Leaf)) {
	throw "jenkins-agent start: no install found; install must run first path=$runnerPath"
}

New-Item -ItemType Directory -Force -Path $AgentDir | Out-Null
Copy-PlatformCaBundle $caPath

# -disableClientsUniqueId makes the Swarm node name the host name, verbatim, which is
# the name stop-jenkins-agent.ps1 looks up.
$agentName = $env:COMPUTERNAME

Write-Host "jenkins-agent start: running the Swarm client name=$agentName labels=$Labels dir=$AgentDir"
# The CA path is passed even when nothing was staged: the runner treats a missing file
# as "no CA bundle", the same as no -TlsCaFile at all.
& $runnerPath $Url $Username (Join-Path $AgentDir 'jenkins.password') `
	$agentName $Labels $AgentDir (Join-Path $AgentDir 'logging.properties') $caPath
exit $LASTEXITCODE
