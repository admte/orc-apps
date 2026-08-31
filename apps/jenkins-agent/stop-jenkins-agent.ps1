$ErrorActionPreference = 'Stop'

# Quiesce hook: the Swarm client is still running and still holds whatever build the
# controller gave it. Mark the node temporarily offline so the queue stops handing it
# work, wait until it reports idle, then exit 0 — stopping the service is the
# runtime's next step, never this script's.

$agentDir = if ($env:AGENT_DIR) { $env:AGENT_DIR } else { 'C:\ProgramData\jenkins-agent' }
$passwordFile = Join-Path $agentDir 'jenkins.password'
# The copy start-jenkins-agent.ps1 staged for the running agent; the fallback for a
# stop that was handed no ca_bundle of its own.
$stagedCaPath = Join-Path $agentDir 'platform-ca.pem'
# Kept under the 30m stop.timeout so the wait ends with a message of its own rather
# than being cut off mid-poll.
$idleTimeout = if ($env:IDLE_TIMEOUT) { [int]$env:IDLE_TIMEOUT } else { 1740 }
$pollInterval = if ($env:POLL_INTERVAL) { [int]$env:POLL_INTERVAL } else { 10 }

$script:jenkinsBase = ''
$script:jenkinsAuth = ''
$script:jenkinsSession = $null
$script:jenkinsCrumbField = ''
$script:jenkinsCrumbValue = ''

# Normalizes a controller URL: drops a trailing slash and rejects anything that is not
# an absolute http(s) URL with a host.
function Get-JenkinsBaseUrl($url) {
	if (-not $url) { throw 'jenkins-agent stop: Jenkins URL is required' }
	$trimmed = $url.TrimEnd('/')
	if (-not ($trimmed.StartsWith('http://') -or $trimmed.StartsWith('https://'))) {
		throw 'jenkins-agent stop: Jenkins URL must start with http:// or https://'
	}
	if (-not $trimmed.Substring($trimmed.IndexOf('://') + 3)) {
		throw 'jenkins-agent stop: Jenkins URL host is required'
	}
	return $trimmed
}

# A session holds the basic-auth header, a cookie jar, and the CSRF crumb the
# controller hands out; every request reuses them, because Jenkins binds the crumb to
# the session that fetched it.
function Open-JenkinsSession($url, $username, $password) {
	$script:jenkinsBase = Get-JenkinsBaseUrl $url
	$pair = [System.Text.Encoding]::UTF8.GetBytes("${username}:${password}")
	$script:jenkinsAuth = 'Basic ' + [System.Convert]::ToBase64String($pair)
	$script:jenkinsSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
	$script:jenkinsCrumbField = ''
	$script:jenkinsCrumbValue = ''
}

function Get-JenkinsHeaders {
	$headers = @{ Authorization = $script:jenkinsAuth }
	if ($script:jenkinsCrumbField -and $script:jenkinsCrumbValue) {
		$headers[$script:jenkinsCrumbField] = $script:jenkinsCrumbValue
	}
	return $headers
}

# Fetches a CSRF crumb into the session. Tolerant by default (a controller with CSRF
# protection disabled answers 404); -Required fails when none comes back.
function Update-JenkinsCrumb([switch]$Required) {
	$script:jenkinsCrumbField = ''
	$script:jenkinsCrumbValue = ''
	try {
		$crumb = Invoke-RestMethod -UseBasicParsing -WebSession $script:jenkinsSession `
			-Headers @{ Authorization = $script:jenkinsAuth } `
			-Uri "$script:jenkinsBase/crumbIssuer/api/json"
		if ($crumb.crumbRequestField -and $crumb.crumb) {
			$script:jenkinsCrumbField = $crumb.crumbRequestField
			$script:jenkinsCrumbValue = $crumb.crumb
		}
	} catch {
		$script:jenkinsCrumbField = ''
		$script:jenkinsCrumbValue = ''
	}
	if ($Required -and (-not $script:jenkinsCrumbValue)) {
		throw 'jenkins-agent stop: failed to fetch the Jenkins CSRF crumb'
	}
}

# The status code out of a failed web request, whichever PowerShell edition raised it;
# 0 when the controller could not be reached at all.
function Get-HttpStatus($errorRecord) {
	$response = $errorRecord.Exception.Response
	if (-not $response) { return 0 }
	try {
		return [int]$response.StatusCode
	} catch {
		return 0
	}
}

# GET that never throws: the parsed body lands in .Body and the HTTP status in
# .Status, so a missing agent (404) is told apart from an unreachable controller (0).
function Invoke-JenkinsGet($path) {
	try {
		$response = Invoke-WebRequest -UseBasicParsing -WebSession $script:jenkinsSession `
			-Headers @{ Authorization = $script:jenkinsAuth } -Uri "$script:jenkinsBase$path"
		$body = $null
		try {
			$body = $response.Content | ConvertFrom-Json
		} catch {
			$body = $null
		}
		return @{ Status = [int]$response.StatusCode; Body = $body }
	} catch {
		return @{ Status = (Get-HttpStatus $_); Body = $null }
	}
}

function Invoke-JenkinsPost($path) {
	Invoke-WebRequest -UseBasicParsing -Method Post -WebSession $script:jenkinsSession `
		-Headers (Get-JenkinsHeaders) -Uri "$script:jenkinsBase$path" | Out-Null
}

# The certificates in a PEM bundle, in order.
#
# X509Certificate2Collection.Import is not used: on .NET Framework it reads only the
# first certificate out of a concatenated PEM, which would silently drop the root of
# an intermediate+root chain.
function Get-PemCertificates($path) {
	$text = [System.IO.File]::ReadAllText($path)
	$blocks = [regex]::Matches($text,
		'-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----',
		[System.Text.RegularExpressions.RegexOptions]::Singleline)
	$certs = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
	foreach ($block in $blocks) {
		$bytes = [System.Convert]::FromBase64String(($block.Groups[1].Value -replace '\s', ''))
		[void]$certs.Add((New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (, $bytes)))
	}
	return , $certs
}

# Adds the platform chain to what this process trusts, for the duration of this
# process only. The runner's twin, and held to the same rule: strictly additive, and
# never a bypass. A certificate is accepted only when the OS already validated it, or
# when the chain rebuilds cleanly and terminates at one of the supplied anchors; a
# name mismatch, an expired leaf, or any other chain error is still fatal.
function Set-PlatformCaTrust($caPath) {
	$anchors = Get-PemCertificates $caPath
	if ($anchors.Count -eq 0) {
		throw "jenkins-agent stop: no certificate in the platform CA bundle: $caPath"
	}
	$thumbprints = @{}
	foreach ($anchor in $anchors) { $thumbprints[$anchor.Thumbprint] = $true }

	[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {
		param($theSender, $certificate, $chain, $sslPolicyErrors)
		if ($sslPolicyErrors -eq [System.Net.Security.SslPolicyErrors]::None) { return $true }
		if ($sslPolicyErrors -ne [System.Net.Security.SslPolicyErrors]::RemoteCertificateChainErrors) {
			return $false
		}
		$leaf = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $certificate
		$rebuilt = New-Object System.Security.Cryptography.X509Certificates.X509Chain
		$rebuilt.ChainPolicy.RevocationMode = 'NoCheck'
		$rebuilt.ChainPolicy.VerificationFlags = 'AllowUnknownCertificateAuthority'
		[void]$rebuilt.ChainPolicy.ExtraStore.AddRange($anchors)
		# Plus whatever the peer presented, so an intermediate that came down the wire
		# rather than out of the bundle still closes the chain. It grants no trust of
		# its own: the anchor test below is what decides.
		if ($chain -and $chain.ChainElements) {
			foreach ($element in $chain.ChainElements) {
				[void]$rebuilt.ChainPolicy.ExtraStore.Add($element.Certificate)
			}
		}
		if (-not $rebuilt.Build($leaf)) { return $false }
		foreach ($element in $rebuilt.ChainElements) {
			foreach ($status in $element.ChainElementStatus) {
				if ($status.Status -ne 'NoError' -and $status.Status -ne 'UntrustedRoot') {
					return $false
				}
			}
		}
		$root = $rebuilt.ChainElements[$rebuilt.ChainElements.Count - 1].Certificate
		return $thumbprints.ContainsKey($root.Thumbprint)
	}.GetNewClosure()
}

if (-not $env:JENKINS_URL) { throw 'jenkins-agent stop: JENKINS_URL is required' }
if (-not $env:JENKINS_USERNAME) { throw 'jenkins-agent stop: JENKINS_USERNAME is required' }

if (-not (Test-Path -LiteralPath $passwordFile -PathType Leaf)) {
	Write-Host "jenkins-agent stop: no install found; nothing to quiesce dir=$agentDir"
	exit 0
}
$jenkinsPassword = ([System.IO.File]::ReadAllText($passwordFile)).Trim([char[]]"`r`n")
if (-not $jenkinsPassword) { throw "jenkins-agent stop: password file is empty: $passwordFile" }

# -disableClientsUniqueId makes the Swarm node name the host name, verbatim.
$node = $env:COMPUTERNAME
if (-not $node) { throw 'jenkins-agent stop: host name is empty' }

# The controller this hook talks to is the one the running agent is connected to, so
# it verifies against the same chain. CA_BUNDLE_FILE is the runtime's materialization
# of the param for this phase; the copy start staged is the fallback, which is what
# answers when the param resolved for start but not for this stop. Neither present
# means the OS trust store, unchanged.
$trustSource = ''
if ($env:CA_BUNDLE_FILE -and (Test-Path -LiteralPath $env:CA_BUNDLE_FILE -PathType Leaf) -and
	(Get-Item -LiteralPath $env:CA_BUNDLE_FILE).Length -gt 0) {
	$trustSource = $env:CA_BUNDLE_FILE
} elseif ((Test-Path -LiteralPath $stagedCaPath -PathType Leaf) -and
	(Get-Item -LiteralPath $stagedCaPath).Length -gt 0) {
	$trustSource = $stagedCaPath
}
if ($trustSource) {
	Set-PlatformCaTrust $trustSource
	Write-Host "jenkins-agent stop: verifying the controller against the platform CA source=$trustSource"
}

Open-JenkinsSession $env:JENKINS_URL $env:JENKINS_USERNAME $jenkinsPassword
$jenkinsPassword = $null
$computer = "/computer/$node"
$reason = if ($env:APP_STOP_REASON) { $env:APP_STOP_REASON } else { 'stop' }
$offlineMessage = [System.Uri]::EscapeDataString("ORC8R node $reason")

function Set-AgentOffline($computer, $offlineMessage) {
	Update-JenkinsCrumb
	try {
		Invoke-JenkinsPost "$computer/toggleOffline?offlineMessage=$offlineMessage"
		return
	} catch {
		# Almost always a missing or stale crumb; take a fresh one and insist.
	}
	Update-JenkinsCrumb -Required
	Invoke-JenkinsPost "$computer/toggleOffline?offlineMessage=$offlineMessage"
}

$status = Invoke-JenkinsGet "$computer/api/json?tree=temporarilyOffline,idle"
switch ($status.Status) {
	200 { }
	404 {
		Write-Host "jenkins-agent stop: agent is not registered on the controller node=$node"
		exit 0
	}
	default {
		throw "jenkins-agent stop: controller did not answer node=$node http_status=$($status.Status)"
	}
}

if ($status.Body.temporarilyOffline) {
	Write-Host "jenkins-agent stop: agent is already offline node=$node"
} else {
	Write-Host "jenkins-agent stop: marking the agent offline so no new build is scheduled node=$node"
	# toggleOffline is a toggle, so it runs only from the online state read above.
	# Nothing clears the mark on the way back: a stop that is really a restart relies
	# on -deleteExistingClients, which drops the stale node when the client
	# reconnects, so the fresh node starts online. Keep that flag in the runner.
	try {
		Set-AgentOffline $computer $offlineMessage
	} catch {
		throw "jenkins-agent stop: failed to mark the agent offline node=$node"
	}
}

Write-Host "jenkins-agent stop: waiting for the current build to finish node=$node timeout=${idleTimeout}s"
$waited = 0
while ($true) {
	$status = Invoke-JenkinsGet "$computer/api/json?tree=idle"
	switch ($status.Status) {
		200 {
			if ($status.Body.idle) {
				Write-Host "jenkins-agent stop: agent is idle; safe to stop node=$node waited=${waited}s"
				exit 0
			}
		}
		404 {
			Write-Host "jenkins-agent stop: agent left the controller; safe to stop node=$node waited=${waited}s"
			exit 0
		}
		default {
			Write-Host "jenkins-agent stop: controller did not answer; retrying node=$node http_status=$($status.Status) waited=${waited}s"
		}
	}
	if ($waited -ge $idleTimeout) { break }
	Start-Sleep -Seconds $pollInterval
	$waited += $pollInterval
}

throw "jenkins-agent stop: agent was still busy after ${idleTimeout}s node=$node"
