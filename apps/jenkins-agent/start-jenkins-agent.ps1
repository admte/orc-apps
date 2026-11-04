$ErrorActionPreference = 'Stop'

# Runs the Swarm client in the foreground, for a service manager to supervise: this
# script is meant to be a service's main process. The package registers nothing with
# the SCM.
#
# There is no privilege drop: Windows has no setpriv and the app carries no service
# account of its own, so the Swarm client runs as the account that runs this script.

$agentDir = if ($env:AGENT_DIR) { $env:AGENT_DIR } else { 'C:\ProgramData\jenkins-agent' }
$runnerDir = if ($env:RUNNER_DIR) { $env:RUNNER_DIR } else { Join-Path $agentDir 'bin' }
$runnerPath = Join-Path $runnerDir 'jenkins-agent.ps1'
# Where the supplied CA chain is staged for the runner and for stop-jenkins-agent.ps1.
$caPath = Join-Path $agentDir 'platform-ca.pem'

# Copies the CA chain in TLS_CA_FILE to a fixed path beside the rest of the agent's
# state. TLS_CA_FILE may be gone once the start is over, and stop-jenkins-agent.ps1
# runs on its own, so it needs a copy that stays.
#
# Copied on every start, never at install: a private CA's certificates may be
# short-lived and renewed by restarting the service, and a chain copied at install
# would go stale. When nothing is supplied the stale copy is removed, so a
# controller that moved to a publicly issued certificate is not left verifying
# against yesterday's chain.
function Copy-PlatformCaBundle($caPath) {
	if ($env:TLS_CA_FILE -and (Test-Path -LiteralPath $env:TLS_CA_FILE -PathType Leaf) -and
		(Get-Item -LiteralPath $env:TLS_CA_FILE).Length -gt 0) {
		Copy-Item -LiteralPath $env:TLS_CA_FILE -Destination $caPath -Force
		Write-Host "jenkins-agent start: staged the supplied CA bundle path=$caPath"
		return
	}
	Remove-Item -Force -LiteralPath $caPath -ErrorAction SilentlyContinue
	Write-Host 'jenkins-agent start: no CA bundle supplied; using the OS trust store'
}

if (-not (Test-Path -LiteralPath $runnerPath -PathType Leaf)) {
	throw "jenkins-agent start: no install found; install must run first path=$runnerPath"
}
if (-not $env:JENKINS_URL) { throw 'jenkins-agent start: JENKINS_URL is required' }
if (-not $env:JENKINS_USERNAME) { throw 'jenkins-agent start: JENKINS_USERNAME is required' }

New-Item -ItemType Directory -Force -Path $agentDir | Out-Null
Copy-PlatformCaBundle $caPath

# -disableClientsUniqueId makes the Swarm node name the host name, verbatim, which is
# the name stop-jenkins-agent.ps1 looks up.
$agentName = $env:COMPUTERNAME
$labels = if ($env:LABELS) { $env:LABELS } else { '' }

Write-Host "jenkins-agent start: running the Swarm client name=$agentName labels=$labels dir=$agentDir"
# The CA path is passed even when nothing was staged: the runner treats a missing file
# as "no CA bundle", the same as no TLS_CA_FILE at all.
& $runnerPath $env:JENKINS_URL $env:JENKINS_USERNAME (Join-Path $agentDir 'jenkins.password') `
	$agentName $labels $agentDir (Join-Path $agentDir 'logging.properties') $caPath
exit $LASTEXITCODE
