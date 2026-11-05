<#
.SYNOPSIS
Configures a JFrog Platform server as the JFrog CLI's default.

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
	if ($TokenFile) {
		if (-not (Test-Path -LiteralPath $TokenFile -PathType Leaf)) {
			throw 'jfrog configure: the token file is not readable'
		}
		return ([System.IO.File]::ReadAllText($TokenFile)).TrimEnd([char[]]"`r`n")
	}
	throw 'jfrog configure: jfrog_token is required'
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
if (-not $Url) {
	throw 'jfrog configure: jfrog_url is required'
}
if (-not $User) {
	throw 'jfrog configure: jfrog_user is required'
}

$token = Get-JFrogToken
if (-not $token) {
	throw 'jfrog configure: jfrog_token is empty'
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
