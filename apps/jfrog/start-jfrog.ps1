<#
.SYNOPSIS
Checks that the JFrog CLI runs and, given all three of a server URL, a user and an access
token file, configures that server as the CLI's default.

.PARAMETER Url
JFrog Platform base URL, e.g. https://example.jfrog.io.

.PARAMETER User
JFrog username.

.PARAMETER TokenFile
File holding a JFrog access token.

.PARAMETER InstallDir
Where install put jf.exe (default: Programs\JFrog under LOCALAPPDATA).
#>
[CmdletBinding()]
param(
	[string]$Url = '',
	[string]$User = '',
	[string]$TokenFile = '',
	[string]$InstallDir = ''
)

$ErrorActionPreference = 'Stop'

function Get-JFrogToken {
	if (-not $TokenFile) {
		return ''
	}
	if (-not (Test-Path -LiteralPath $TokenFile -PathType Leaf)) {
		throw 'jfrog configure: the token file is not readable'
	}
	return ([System.IO.File]::ReadAllText($TokenFile)).TrimEnd([char[]]"`r`n")
}

$command = Get-Command jf -ErrorAction SilentlyContinue
if ($command) {
	$jf = $command.Source
} else {
	$installDir = if ($InstallDir) {
		$InstallDir
	} else {
		Join-Path $env:LOCALAPPDATA 'Programs\JFrog'
	}
	$jf = Join-Path $installDir 'jf.exe'
}
if (-not (Test-Path -LiteralPath $jf -PathType Leaf)) {
	throw 'jfrog configure: JFrog CLI is not installed'
}
& $jf --version | Out-Null
if ($LASTEXITCODE -ne 0) {
	throw "jfrog configure: CLI version check failed with exit code $LASTEXITCODE"
}

# Credentials are optional: with none supplied the app's job is done once the
# CLI is installed and runnable. Configuring a server needs all three together.
$token = Get-JFrogToken
if (-not $Url -and -not $User -and -not $token) {
	Write-Host 'JFrog CLI is ready; credentials were not provided'
	exit 0
}
if (-not $Url) {
	throw 'jfrog configure: jfrog_url is required to configure a server'
}
if (-not $User) {
	throw 'jfrog configure: jfrog_user is required to configure a server'
}
if (-not $token) {
	throw 'jfrog configure: jfrog_token is required to configure a server'
}

Write-Host "Configuring JFrog CLI server 'orc'"
$env:CI = 'true'
$token | & $jf config add orc `
	"--url=$Url" `
	"--user=$User" `
	--access-token-stdin `
	--interactive=false `
	--overwrite
if ($LASTEXITCODE -ne 0) {
	throw "jfrog configure: config add failed with exit code $LASTEXITCODE"
}
$token = $null

& $jf config use orc
if ($LASTEXITCODE -ne 0) {
	throw "jfrog configure: config use failed with exit code $LASTEXITCODE"
}
Write-Host 'JFrog CLI configuration complete'
