<#
.SYNOPSIS
Installs the AWS CLI v2.

.DESCRIPTION
Without -Version it installs the latest release, and leaves an aws command that is
already on PATH as it is.

.PARAMETER Version
AWS CLI release to install, e.g. 2.17.0.

.PARAMETER Force
Install even when aws is already on PATH.
#>
[CmdletBinding()]
param(
	[string]$Version = '',
	[switch]$Force
)

$ErrorActionPreference = 'Stop'

$existing = Get-Command aws -ErrorAction SilentlyContinue
if ($existing -and -not $Version -and -not $Force) {
	& $existing.Source --version
	exit 0
}

if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
	throw "aws install: unsupported architecture $env:PROCESSOR_ARCHITECTURE"
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "aws-cli-$([guid]::NewGuid())"
try {
	New-Item -ItemType Directory -Path $tmp -Force | Out-Null
	$msi = Join-Path $tmp 'AWSCLIV2.msi'
	$msiUrl = if ($Version) {
		"https://awscli.amazonaws.com/AWSCLIV2-$Version.msi"
	} else {
		'https://awscli.amazonaws.com/AWSCLIV2.msi'
	}
	Write-Host 'Downloading AWS CLI v2 for windows/amd64'
	Invoke-WebRequest -UseBasicParsing -Uri $msiUrl -OutFile $msi

	$process = Start-Process msiexec.exe -ArgumentList @('/i', "`"$msi`"", '/qn', '/norestart') `
		-Wait -PassThru
	if ($process.ExitCode -ne 0) {
		throw "aws install: msiexec failed with exit code $($process.ExitCode)"
	}

	$aws = Join-Path $env:ProgramFiles 'Amazon\AWSCLIV2\aws.exe'
	if (-not (Test-Path -LiteralPath $aws -PathType Leaf)) {
		throw "aws install: AWS CLI executable was not found at $aws"
	}
	& $aws --version
} finally {
	Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
