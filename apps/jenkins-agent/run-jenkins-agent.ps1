# The Windows twin of run-jenkins-agent.sh: asks the controller which Java it runs and
# which Swarm plugin it serves, puts a matching Temurin JDK and the controller's own
# swarm-client.jar in place, then runs the client until the service is stopped.
#
# Installed at a fixed path by install-jenkins-agent.ps1 and invoked from
# start-jenkins-agent.ps1, so the arguments mirror the Linux runner's positionals.
# Parameters are deliberately not `Mandatory`: a missing one must fail loudly rather
# than block a service start on an interactive prompt nobody will answer.
param(
	[string]$JenkinsUrl,
	[string]$JenkinsUsername,
	[string]$PasswordFile,
	[string]$AgentName,
	[string]$Labels,
	[string]$AgentDir,
	[string]$LogConfigPath,
	# Optional so an older start script -- one from a package installed before the
	# tls_ca param existed -- still runs this runner unchanged.
	[string]$CaBundlePath
)

$ErrorActionPreference = 'Stop'
# Invoke-WebRequest renders a progress bar per read on Windows PowerShell, which turns
# a JDK download into a multi-minute crawl.
$ProgressPreference = 'SilentlyContinue'

$script:jenkinsBase = ''
$script:jenkinsAuth = ''
$script:jenkinsSession = $null
$script:jenkinsCrumbField = ''
$script:jenkinsCrumbValue = ''

# Normalizes a controller URL: drops a trailing slash and rejects anything that is not
# an absolute http(s) URL with a host.
function Get-JenkinsBaseUrl($url) {
	if (-not $url) { throw 'jenkins-agent runner: Jenkins URL is required' }
	$trimmed = $url.TrimEnd('/')
	if (-not ($trimmed.StartsWith('http://') -or $trimmed.StartsWith('https://'))) {
		throw 'jenkins-agent runner: Jenkins URL must start with http:// or https://'
	}
	if (-not $trimmed.Substring($trimmed.IndexOf('://') + 3)) {
		throw 'jenkins-agent runner: Jenkins URL host is required'
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
		throw 'jenkins-agent runner: failed to fetch the Jenkins CSRF crumb'
	}
}

function Invoke-JenkinsScriptText($body) {
	return [string](Invoke-RestMethod -UseBasicParsing -Method Post `
			-WebSession $script:jenkinsSession -Headers (Get-JenkinsHeaders) `
			-ContentType 'application/x-www-form-urlencoded' -Body $body `
			-Uri "$script:jenkinsBase/scriptText")
}

function Get-JenkinsControllerInfo {
	$groovy = @'
import groovy.json.JsonOutput;

swarmPlugin = Jenkins.instance.pluginManager.getPlugin("swarm")

println JsonOutput.toJson([
    JavaVersion: System.getProperty("java.version"),
    SwarmPluginVersion: (swarmPlugin ? swarmPlugin.version : null),
])
'@
	$body = 'script=' + [System.Uri]::EscapeDataString($groovy)

	Update-JenkinsCrumb
	$response = ''
	try {
		$response = Invoke-JenkinsScriptText $body
	} catch {
		$response = ''
	}
	if ($response -notmatch '"JavaVersion"') {
		# A stale or missing crumb is the usual cause; take a fresh one and insist.
		Update-JenkinsCrumb -Required
		$response = Invoke-JenkinsScriptText $body
	}
	return ($response | ConvertFrom-Json)
}

function Get-JavaMajor($version) {
	$value = ([string]$version).Trim().Trim('"')
	if ($value.StartsWith('1.')) {
		return $value.Split('.')[1]
	}
	$match = [regex]::Match($value, '^(\d+)')
	if (-not $match.Success) {
		throw "jenkins-agent runner: invalid Java version $value"
	}
	return $match.Groups[1].Value
}

function Get-InstalledJavaMajor($javaBinary) {
	# `java -version` writes to stderr, and a native command's stderr merged into the
	# pipeline is a terminating error while $ErrorActionPreference is 'Stop'.
	$previous = $ErrorActionPreference
	$ErrorActionPreference = 'Continue'
	try {
		$output = (& $javaBinary -version 2>&1 | Out-String)
	} catch {
		return ''
	} finally {
		$ErrorActionPreference = $previous
	}
	$match = [regex]::Match($output, 'version "([^"]+)"')
	if (-not $match.Success) {
		return ''
	}
	return (Get-JavaMajor $match.Groups[1].Value)
}

function Get-TemurinArch {
	switch ($env:PROCESSOR_ARCHITECTURE) {
		'AMD64' { return 'x64' }
		'ARM64' { return 'aarch64' }
		default { throw "jenkins-agent runner: unsupported architecture $env:PROCESSOR_ARCHITECTURE" }
	}
}

function Get-TemurinDownloadUrl($javaMajor) {
	$arch = Get-TemurinArch
	$release = Invoke-RestMethod -UseBasicParsing -Headers @{ Accept = 'application/vnd.github+json' } `
		-Uri "https://api.github.com/repos/adoptium/temurin$javaMajor-binaries/releases/latest"
	$needle = "OpenJDK${javaMajor}U-jdk_${arch}_windows_hotspot_"
	$asset = $release.assets |
		Where-Object { $_.name -and $_.browser_download_url -and $_.name.StartsWith($needle) -and $_.name.EndsWith('.zip') } |
		Select-Object -First 1
	if (-not $asset) {
		throw "jenkins-agent runner: no matching Temurin asset for $needle"
	}
	return $asset.browser_download_url
}

# curl's --retry has no Invoke-WebRequest equivalent on Windows PowerShell, so the
# retry the Linux runner gets for free is spelled out here.
function Save-Download($uri, $outFile, $headers) {
	for ($attempt = 1; $attempt -le 5; $attempt++) {
		try {
			Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $outFile -Headers $headers
			return
		} catch {
			if ($attempt -ge 5) { throw }
			Write-Host "jenkins-agent runner: download failed; retrying attempt=$attempt/5 uri=$uri"
			Start-Sleep -Seconds 3
		}
	}
}

function Install-TemurinJava($javaMajor) {
	$javaHomeDir = Join-Path $AgentDir "java-temurin-$javaMajor"
	$downloadUrl = Get-TemurinDownloadUrl $javaMajor
	$tempDir = New-Item -ItemType Directory -Force `
		-Path (Join-Path $AgentDir "temurin-$([guid]::NewGuid())")
	try {
		Write-Host "jenkins-agent runner: downloading Temurin JDK java=$javaMajor url=$downloadUrl"
		$archive = Join-Path $tempDir.FullName 'temurin.zip'
		Save-Download $downloadUrl $archive @{}
		if (-not (Test-Path -LiteralPath $archive) -or (Get-Item -LiteralPath $archive).Length -eq 0) {
			throw 'jenkins-agent runner: downloaded Temurin archive is empty'
		}
		Expand-Archive -Force -Path $archive -DestinationPath $tempDir.FullName
		Remove-Item -Force -LiteralPath $archive

		# Temurin zips carry a single versioned top-level directory; take it if the
		# archive did not unpack flat.
		$javaHome = $tempDir.FullName
		if (-not (Test-Path -LiteralPath (Join-Path $javaHome 'bin\java.exe'))) {
			$javaHome = ''
			foreach ($candidate in (Get-ChildItem -Directory -LiteralPath $tempDir.FullName)) {
				if (Test-Path -LiteralPath (Join-Path $candidate.FullName 'bin\java.exe')) {
					$javaHome = $candidate.FullName
					break
				}
			}
			if (-not $javaHome) {
				throw 'jenkins-agent runner: java home with bin\java.exe not found in the Temurin archive'
			}
		}
		if (Test-Path -LiteralPath $javaHomeDir) {
			Remove-Item -Recurse -Force -LiteralPath $javaHomeDir
		}
		Move-Item -LiteralPath $javaHome -Destination $javaHomeDir
	} finally {
		Remove-Item -Recurse -Force -LiteralPath $tempDir.FullName -ErrorAction SilentlyContinue
	}
}

function Get-MatchingJava($javaMajor) {
	$javaBinary = Join-Path (Join-Path $AgentDir "java-temurin-$javaMajor") 'bin\java.exe'
	$localMajor = ''
	if (Test-Path -LiteralPath $javaBinary -PathType Leaf) {
		$localMajor = Get-InstalledJavaMajor $javaBinary
	}
	if ($localMajor -ne $javaMajor) {
		Write-Host "jenkins-agent runner: local Java does not match the controller; updating java=$javaMajor"
		Install-TemurinJava $javaMajor
	}
	return $javaBinary
}

function Update-SwarmClientJar($swarmJarPath) {
	$temp = Join-Path $AgentDir "swarm-client-$([guid]::NewGuid()).jar"
	try {
		Save-Download "$script:jenkinsBase/swarm/swarm-client.jar" $temp `
			@{ Authorization = $script:jenkinsAuth }
		if (-not (Test-Path -LiteralPath $temp) -or (Get-Item -LiteralPath $temp).Length -eq 0) {
			throw 'jenkins-agent runner: downloaded swarm-client.jar is empty'
		}
		$current = ''
		if (Test-Path -LiteralPath $swarmJarPath -PathType Leaf) {
			$current = (Get-FileHash -Algorithm SHA256 -LiteralPath $swarmJarPath).Hash
		}
		if ($current -eq (Get-FileHash -Algorithm SHA256 -LiteralPath $temp).Hash) {
			Write-Host 'jenkins-agent runner: swarm-client.jar matches the controller'
		} else {
			Move-Item -LiteralPath $temp -Destination $swarmJarPath -Force
			Write-Host 'jenkins-agent runner: updated swarm-client.jar from the controller'
		}
	} finally {
		Remove-Item -Force -LiteralPath $temp -ErrorAction SilentlyContinue
	}
}

# The certificates in a PEM bundle, in order.
#
# X509Certificate2Collection.Import is not used: on .NET Framework it reads only the
# first certificate out of a concatenated PEM, which would silently drop the root of
# an intermediate+root chain. Splitting on the armour and decoding each block is the
# same thing keytool is handed on the JDK side.
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
# process only.
#
# Invoke-WebRequest has no --cacert: its verification is the OS store's, and the
# platform CA is not in it. A per-process validation callback is the one supported way
# to add an anchor without writing to LocalMachine\Root, which would need admin, would
# outlive the app, and would go stale on the next renewal.
#
# The callback is strictly additive and never a bypass. It accepts a certificate in
# exactly two cases: the OS already validated it, or the chain rebuilds cleanly and
# terminates at one of the certificates in the supplied bundle. A name mismatch, an
# expired leaf, an unavailable certificate, or any chain error other than "this root
# is not in the OS store" is still a failure -- there is no branch that returns true
# for an unverified peer.
function Set-PlatformCaTrust($caPath) {
	$anchors = Get-PemCertificates $caPath
	if ($anchors.Count -eq 0) {
		throw "jenkins-agent runner: no certificate in the platform CA bundle: $caPath"
	}
	$thumbprints = @{}
	foreach ($anchor in $anchors) { $thumbprints[$anchor.Thumbprint] = $true }

	[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {
		param($theSender, $certificate, $chain, $sslPolicyErrors)
		if ($sslPolicyErrors -eq [System.Net.Security.SslPolicyErrors]::None) { return $true }
		# Only an unknown authority is up for reconsideration. Anything else -- above
		# all RemoteCertificateNameMismatch -- stays fatal.
		if ($sslPolicyErrors -ne [System.Net.Security.SslPolicyErrors]::RemoteCertificateChainErrors) {
			return $false
		}
		$leaf = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $certificate
		$rebuilt = New-Object System.Security.Cryptography.X509Certificates.X509Chain
		# Matches the platform default (ServicePointManager does not check revocation
		# unless asked); it is not a relaxation of this path relative to the other.
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

# Rebuilds the JVM's truststore: a copy of the JDK's own cacerts with the platform
# chain added to it.
#
# A copy rather than the JDK's cacerts in place, because the runner replaces that
# whole JDK directory whenever the controller's Java major version changes -- an
# import into the downloaded artifact would be silently discarded by the next swap,
# and a mutated artifact no longer matches what was downloaded. Rebuilding from
# whichever JDK is current, on every start, is idempotent by construction: there is no
# alias to delete first and no way to drift.
#
# Copying cacerts rather than building an empty store keeps the public roots, so a
# controller with a publicly issued certificate verifies through the same truststore.
function Build-JavaTrustStore($javaHomeDir, $caPath, $trustStorePath) {
	$sourceStore = Join-Path $javaHomeDir 'lib\security\cacerts'
	$keytool = Join-Path $javaHomeDir 'bin\keytool.exe'
	if (-not (Test-Path -LiteralPath $sourceStore -PathType Leaf)) {
		throw "jenkins-agent runner: JDK truststore not found: $sourceStore"
	}
	if (-not (Test-Path -LiteralPath $keytool -PathType Leaf)) {
		throw "jenkins-agent runner: keytool not found: $keytool"
	}
	Copy-Item -LiteralPath $sourceStore -Destination $trustStorePath -Force

	$imported = 0
	foreach ($cert in (Get-PemCertificates $caPath)) {
		$imported++
		# keytool -importcert takes one certificate per alias, and reads DER as
		# happily as PEM.
		$certFile = Join-Path $AgentDir "orc-platform-ca-$imported.cer"
		try {
			[System.IO.File]::WriteAllBytes($certFile, $cert.RawData)
			# keytool writes its progress to stderr, which is a terminating error
			# while $ErrorActionPreference is 'Stop'.
			$previous = $ErrorActionPreference
			$ErrorActionPreference = 'Continue'
			try {
				& $keytool -importcert -noprompt -trustcacerts `
					-alias "orc-platform-ca-$imported" -file $certFile `
					-keystore $trustStorePath -storepass changeit 2>&1 | Out-Null
			} finally {
				$ErrorActionPreference = $previous
			}
			if ($LASTEXITCODE -ne 0) {
				throw "jenkins-agent runner: failed to import the platform CA alias=orc-platform-ca-$imported"
			}
		} finally {
			Remove-Item -Force -LiteralPath $certFile -ErrorAction SilentlyContinue
		}
	}
	if ($imported -eq 0) {
		throw "jenkins-agent runner: no certificate in the platform CA bundle: $caPath"
	}
	Write-Host "jenkins-agent runner: rebuilt the JVM truststore certs=$imported path=$trustStorePath"
}

if (-not $JenkinsUrl) { throw 'jenkins-agent runner: Jenkins URL is required' }
if (-not $JenkinsUsername) { throw 'jenkins-agent runner: Jenkins username is required' }
if (-not $PasswordFile) { throw 'jenkins-agent runner: password file is required' }
if (-not $AgentDir) { throw 'jenkins-agent runner: agent directory is required' }
if (-not $LogConfigPath) { throw 'jenkins-agent runner: logging config is required' }
if (-not $AgentName) { $AgentName = $env:COMPUTERNAME }
if (-not $AgentName) { throw 'jenkins-agent runner: agent name is empty' }

if (-not (Test-Path -LiteralPath $PasswordFile -PathType Leaf)) {
	throw "jenkins-agent runner: password file is not readable: $PasswordFile"
}
$jenkinsPassword = ([System.IO.File]::ReadAllText($PasswordFile)).Trim([char[]]"`r`n")
if (-not $jenkinsPassword) { throw "jenkins-agent runner: password file is empty: $PasswordFile" }

$swarmJarPath = Join-Path $AgentDir 'swarm-client.jar'
# The JDK's own cacerts plus the platform chain, for the JVM.
$trustStorePath = Join-Path $AgentDir 'truststore.p12'

# Before the first controller call, and unconditionally on every start: the platform
# renews its certificates by restarting this app, so the chain staged for this run is
# the only one that can be trusted to be current. With none supplied, nothing is
# installed and verification stays the OS store's, exactly as it always was.
if ($CaBundlePath -and (Test-Path -LiteralPath $CaBundlePath -PathType Leaf) -and
	(Get-Item -LiteralPath $CaBundlePath).Length -gt 0) {
	Set-PlatformCaTrust $CaBundlePath
	Write-Host "jenkins-agent runner: verifying the controller against the platform CA path=$CaBundlePath"
} else {
	$CaBundlePath = ''
	Remove-Item -Force -LiteralPath $trustStorePath -ErrorAction SilentlyContinue
	Write-Host 'jenkins-agent runner: no platform CA supplied; verifying against the OS trust store'
}

Open-JenkinsSession $JenkinsUrl $JenkinsUsername $jenkinsPassword
$controller = Get-JenkinsControllerInfo
$javaVersion = $controller.JavaVersion
$swarmVersion = $controller.SwarmPluginVersion
if (-not $javaVersion) { throw 'jenkins-agent runner: Jenkins Java version is empty' }
if (-not $swarmVersion) { throw 'jenkins-agent runner: Jenkins Swarm plugin is not installed' }
$javaMajor = Get-JavaMajor $javaVersion

Write-Host "jenkins-agent runner: controller java=$javaVersion java_major=$javaMajor swarm_plugin=$swarmVersion"
$javaBinary = Get-MatchingJava $javaMajor
# After the JDK is settled, so a swap is followed by a fresh import rather than
# leaving the new JDK trusting nothing but the public roots.
if ($CaBundlePath) {
	Build-JavaTrustStore (Join-Path $AgentDir "java-temurin-$javaMajor") $CaBundlePath $trustStorePath
}
Update-SwarmClientJar $swarmJarPath

# -retry/-retryInterval keep the client reconnecting across a controller restart
# instead of exiting; the app is not failed for an outage it is expected to ride out.
# -noRetryAfterConnected is deliberately absent: it turns a dropped connection into an
# exit. Windows has no exec, so the JVM runs as a child of this script — the service
# shim ends the whole process tree, so the stop still reaches it.
#
# The JVM does not read the OS trust store; it reads a truststore of its own, so the
# validation callback above does nothing for the Swarm client. When the platform
# handed us a chain, the client is pointed at the rebuilt copy of the JDK's cacerts
# that carries it -- otherwise at nothing, and the JDK's own default applies. No flag
# here weakens verification.
$trustArgs = @()
if ($CaBundlePath) {
	$trustArgs = @(
		"-Djavax.net.ssl.trustStore=$trustStorePath",
		'-Djavax.net.ssl.trustStorePassword=changeit'
	)
}
$javaArgs = @(
	"-Djava.util.logging.config.file=$LogConfigPath"
) + $trustArgs + @(
	'-jar', $swarmJarPath,
	'-name', $AgentName,
	'-mode', 'exclusive',
	'-executors', '1',
	'-labels', $Labels,
	'-fsroot', $AgentDir,
	'-deleteExistingClients',
	'-disableClientsUniqueId',
	'-retry', '5',
	'-retryInterval', '10',
	'-master', $JenkinsUrl,
	'-username', $JenkinsUsername,
	'-passwordFile', $PasswordFile,
	'-webSocket'
)

Write-Host "jenkins-agent runner: starting the Swarm client name=$AgentName labels=$Labels"
# The Swarm client logs through java.util.logging, which writes every line to stderr;
# under 'Stop' the first of them would end the script as a terminating error.
$ErrorActionPreference = 'Continue'
& $javaBinary @javaArgs
exit $LASTEXITCODE
