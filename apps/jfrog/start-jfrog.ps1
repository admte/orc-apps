$ErrorActionPreference = 'Stop'

function Get-JFrogToken {
	if ($env:JFROG_TOKEN_FILE) {
		if (-not (Test-Path -LiteralPath $env:JFROG_TOKEN_FILE -PathType Leaf)) {
			throw 'jfrog configure: JFROG_TOKEN_FILE is not readable'
		}
		return ([System.IO.File]::ReadAllText($env:JFROG_TOKEN_FILE)).TrimEnd([char[]]"`r`n")
	}
	if ($env:JFROG_TOKEN) {
		return $env:JFROG_TOKEN
	}
	throw 'jfrog configure: jfrog_token is required'
}

$command = Get-Command jf -ErrorAction SilentlyContinue
if ($command) {
	$jf = $command.Source
} else {
	$installDir = if ($env:JFROG_CLI_INSTALL_DIR) {
		$env:JFROG_CLI_INSTALL_DIR
	} else {
		Join-Path $env:LOCALAPPDATA 'Programs\JFrog'
	}
	$jf = Join-Path $installDir 'jf.exe'
}
if (-not (Test-Path -LiteralPath $jf -PathType Leaf)) {
	throw 'jfrog configure: JFrog CLI is not installed'
}
if (-not $env:JFROG_URL) {
	throw 'jfrog configure: jfrog_url is required'
}
if (-not $env:JFROG_USER) {
	throw 'jfrog configure: jfrog_user is required'
}

$token = Get-JFrogToken
if (-not $token) {
	throw 'jfrog configure: jfrog_token is empty'
}

Write-Host "Configuring JFrog CLI server 'orc'"
$env:CI = 'true'
$token | & $jf config add orc `
	"--url=$env:JFROG_URL" `
	"--user=$env:JFROG_USER" `
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
