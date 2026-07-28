$ErrorActionPreference = 'Stop'

function Get-OrcParameter {
	param([Parameter(Mandatory = $true)][string] $Name)

	$value = [Environment]::GetEnvironmentVariable($Name)
	$file = [Environment]::GetEnvironmentVariable("${Name}_FILE")
	if ($file) {
		if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
			throw 'aws configure: credential file is not readable'
		}
		return ([System.IO.File]::ReadAllText($file)).TrimEnd([char[]]"`r`n")
	}
	return $value
}

$command = Get-Command aws -ErrorAction SilentlyContinue
if ($command) {
	$aws = $command.Source
} else {
	$aws = Join-Path $env:ProgramFiles 'Amazon\AWSCLIV2\aws.exe'
}
if (-not (Test-Path -LiteralPath $aws -PathType Leaf)) {
	throw 'aws configure: AWS CLI is not installed'
}
& $aws --version | Out-Null

$accessKey = Get-OrcParameter -Name 'AWS_ACCESS_KEY_ID'
$secretKey = Get-OrcParameter -Name 'AWS_SECRET_ACCESS_KEY'
if ([bool]$accessKey -ne [bool]$secretKey) {
	throw 'aws configure: aws_access_key_id and aws_secret_access_key must be provided together'
}
if (-not $accessKey) {
	Write-Host 'AWS CLI is ready; credentials were not provided'
	exit 0
}

$homeDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
if (-not $homeDir) {
	throw 'aws configure: user home directory is required'
}
$credentialsFile = if ($env:AWS_SHARED_CREDENTIALS_FILE) {
	$env:AWS_SHARED_CREDENTIALS_FILE
} else {
	Join-Path $homeDir '.aws\credentials'
}
$credentialsDir = Split-Path -Parent $credentialsFile
New-Item -ItemType Directory -Path $credentialsDir -Force | Out-Null

$remaining = [System.Collections.Generic.List[string]]::new()
$skip = $false
if (Test-Path -LiteralPath $credentialsFile -PathType Leaf) {
	foreach ($line in [System.IO.File]::ReadAllLines($credentialsFile)) {
		if ($line -match '^\s*\[[^\]]+\]\s*$') {
			$skip = $line -match '^\s*\[default\]\s*$'
		}
		if (-not $skip) {
			$remaining.Add($line)
		}
	}
}

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('[default]')
$lines.Add("aws_access_key_id = $accessKey")
$lines.Add("aws_secret_access_key = $secretKey")
$lines.AddRange($remaining)
$accessKey = $null
$secretKey = $null

$tmp = Join-Path $credentialsDir ".credentials-$([guid]::NewGuid())"
try {
	$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
	[System.IO.File]::WriteAllLines($tmp, $lines, $utf8NoBom)
	Move-Item -LiteralPath $tmp -Destination $credentialsFile -Force
} finally {
	Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}

Write-Host 'AWS CLI credentials configured'
