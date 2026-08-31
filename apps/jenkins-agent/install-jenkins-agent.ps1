$ErrorActionPreference = 'Stop'

# Install phase: lays out the agent directory, the logging config, the password the
# Swarm client re-reads on every restart, and a copy of the runner at a fixed path.
#
# Nothing here contacts the controller and nothing here is node identity. A pool bake
# runs the install phase alone and snapshots the disk, so everything install writes is
# shared by every clone of that image; the agent registers itself when the runner
# connects, under the host name of the node that is actually running.
#
# There is no service account and no service registration. On Windows the app runs as
# the account the runtime runs as — there is no setpriv and no `jenkins` account to
# drop to — and the node owns the service definition, generating it from `start:`.

$agentDir = if ($env:AGENT_DIR) { $env:AGENT_DIR } else { 'C:\ProgramData\jenkins-agent' }
$runnerDir = if ($env:RUNNER_DIR) { $env:RUNNER_DIR } else { Join-Path $agentDir 'bin' }
$runnerPath = Join-Path $runnerDir 'jenkins-agent.ps1'
$logConfigPath = Join-Path $agentDir 'logging.properties'
$passwordFile = Join-Path $agentDir 'jenkins.password'

function Get-JenkinsPassword {
	if ($env:JENKINS_PASSWORD_FILE) {
		if (-not (Test-Path -LiteralPath $env:JENKINS_PASSWORD_FILE -PathType Leaf)) {
			throw 'jenkins-agent install: JENKINS_PASSWORD_FILE is not readable'
		}
		return ([System.IO.File]::ReadAllText($env:JENKINS_PASSWORD_FILE)).Trim([char[]]"`r`n")
	}
	if ($env:JENKINS_PASSWORD) {
		return $env:JENKINS_PASSWORD
	}
	throw 'jenkins-agent install: JENKINS_PASSWORD_FILE or JENKINS_PASSWORD is required'
}

# UTF-8 without a BOM, and no trailing newline: the Swarm client reads the password
# file verbatim, so a byte-order mark would travel as part of the password.
function Write-TextFile($path, $text) {
	[System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

# The password outlives the install phase: the sensitive param file is withdrawn once
# the app has started, while the Swarm client re-reads its password on every service
# restart. Only the accounts that can run the service may read it, so inheritance is
# dropped and the access rules are rebuilt from well-known SIDs (LocalSystem, the
# local Administrators group) plus whoever is installing.
function Protect-PasswordFile($path) {
	$acl = Get-Acl -LiteralPath $path
	$acl.SetAccessRuleProtection($true, $false)
	foreach ($rule in @($acl.Access)) {
		[void]$acl.RemoveAccessRule($rule)
	}
	$identities = @(
		(New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18'),
		(New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544')
	)
	$current = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
	if ($current -and ($identities -notcontains $current)) {
		$identities += $current
	}
	foreach ($identity in $identities) {
		$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
					$identity, 'FullControl', 'Allow')))
	}
	Set-Acl -LiteralPath $path -AclObject $acl
}

if (-not $env:JENKINS_URL) { throw 'jenkins-agent install: JENKINS_URL is required' }
if (-not $env:JENKINS_USERNAME) { throw 'jenkins-agent install: JENKINS_USERNAME is required' }

$jenkinsPassword = Get-JenkinsPassword
if (-not $jenkinsPassword) { throw 'jenkins-agent install: the Jenkins password is empty' }

Write-Host "jenkins-agent install: preparing the agent directory dir=$agentDir"
New-Item -ItemType Directory -Force -Path $agentDir | Out-Null

Write-Host "jenkins-agent install: writing the logging config path=$logConfigPath"
# A single-quoted here-string: the SimpleFormatter pattern is full of `$` sequences
# that PowerShell would otherwise read as variables.
$loggingConfig = @'
.level = INFO
handlers= java.util.logging.ConsoleHandler

java.util.logging.ConsoleHandler.level=INFO
java.util.logging.ConsoleHandler.formatter=java.util.logging.SimpleFormatter
java.util.logging.SimpleFormatter.format = %4$s %2$s %5$s%6$s%n
'@
Write-TextFile $logConfigPath ($loggingConfig + "`n")

Write-Host "jenkins-agent install: writing the password file path=$passwordFile"
Write-TextFile $passwordFile $jenkinsPassword
Protect-PasswordFile $passwordFile
$jenkinsPassword = $null

# The runner lives at a fixed path so the service definition the node writes keeps
# working regardless of where the app's working directory lands, and so a baked image
# carries a complete agent.
Write-Host "jenkins-agent install: installing the runner path=$runnerPath"
$runnerSource = Join-Path $PSScriptRoot 'run-jenkins-agent.ps1'
if (-not (Test-Path -LiteralPath $runnerSource -PathType Leaf)) {
	throw "jenkins-agent install: runner script not found in $PSScriptRoot"
}
New-Item -ItemType Directory -Force -Path $runnerDir | Out-Null
Copy-Item -LiteralPath $runnerSource -Destination $runnerPath -Force

Write-Host "jenkins-agent install: complete dir=$agentDir runner=$runnerPath"
