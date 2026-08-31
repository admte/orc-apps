$ErrorActionPreference = 'Stop'

# Start phase: the packaged script that replaced the inline `start.command`, so each
# platform resolves its own start. A start command that resolves — from config or, as
# here, from a packaged script — together with `start.service: jenkins-agent` is what
# selects runtime-managed service mode, so the node writes the service definition
# itself and this package registers nothing with the SCM.
#
# There is no privilege drop: Windows has no setpriv and the app carries no service
# account of its own, so the Swarm client runs as the account the runtime runs as.

$agentDir = if ($env:AGENT_DIR) { $env:AGENT_DIR } else { 'C:\ProgramData\jenkins-agent' }
$runnerDir = if ($env:RUNNER_DIR) { $env:RUNNER_DIR } else { Join-Path $agentDir 'bin' }
$runnerPath = Join-Path $runnerDir 'jenkins-agent.ps1'
# Where the platform chain is staged for the runner and for the stop hook.
$caPath = Join-Path $agentDir 'platform-ca.pem'

# Copies the platform's trust chain to a fixed path beside the rest of the agent's
# state. TLS_CA_FILE is the runtime's own materialization of the `tls_ca`
# param; it is withdrawn when the app stops, and the stop hook is a phase of its own.
#
# Copied on every start, never at install: the platform's certificates are short-lived
# and renewed by restarting the app, and install is also the phase a pool bake
# snapshots — a chain baked into an image would be stale on first boot. When nothing
# is supplied the stale copy is removed, so a controller that moved to a publicly
# issued certificate is not left verifying against yesterday's chain.
function Copy-PlatformCaBundle($caPath) {
	if ($env:TLS_CA_FILE -and (Test-Path -LiteralPath $env:TLS_CA_FILE -PathType Leaf) -and
		(Get-Item -LiteralPath $env:TLS_CA_FILE).Length -gt 0) {
		Copy-Item -LiteralPath $env:TLS_CA_FILE -Destination $caPath -Force
		Write-Host "jenkins-agent start: staged the platform CA bundle path=$caPath"
		return
	}
	Remove-Item -Force -LiteralPath $caPath -ErrorAction SilentlyContinue
	Write-Host 'jenkins-agent start: no platform CA supplied; using the OS trust store'
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
# as "no platform CA", which is the same thing an unresolved param means.
& $runnerPath $env:JENKINS_URL $env:JENKINS_USERNAME (Join-Path $agentDir 'jenkins.password') `
	$agentName $labels $agentDir (Join-Path $agentDir 'logging.properties') $caPath
exit $LASTEXITCODE
