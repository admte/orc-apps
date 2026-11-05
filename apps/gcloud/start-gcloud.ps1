<#
.SYNOPSIS
Checks that the Google Cloud CLI runs and, given a service account key file, activates
that service account.

.PARAMETER ServiceAccountKeyFile
File holding a service account JSON key.

.PARAMETER InstallDir
Where install put the SDK (default: Google\Cloud SDK under LOCALAPPDATA).
#>
[CmdletBinding()]
param(
	[string]$ServiceAccountKeyFile = '',
	[string]$InstallDir = ''
)

$ErrorActionPreference = 'Stop'

$command = Get-Command gcloud -ErrorAction SilentlyContinue
if ($command) {
	$gcloud = $command.Source
} else {
	$installRoot = if ($InstallDir) {
		$InstallDir
	} else {
		Join-Path $env:LOCALAPPDATA 'Google\Cloud SDK'
	}
	$candidates = @(
		(Join-Path $installRoot 'google-cloud-sdk\bin\gcloud.cmd'),
		(Join-Path $installRoot 'bin\gcloud.cmd')
	)
	$gcloud = $candidates | Where-Object {
		Test-Path -LiteralPath $_ -PathType Leaf
	} | Select-Object -First 1
}
if (-not $gcloud -or -not (Test-Path -LiteralPath $gcloud -PathType Leaf)) {
	throw 'gcloud configure: Google Cloud CLI is not installed'
}

& $gcloud version | Out-Null
if ($LASTEXITCODE -ne 0) {
	throw "gcloud configure: CLI version check failed with exit code $LASTEXITCODE"
}

$keyFile = $ServiceAccountKeyFile
if (-not $keyFile) {
	Write-Host 'Google Cloud CLI is ready; service account key was not provided'
	exit 0
}
if (-not (Test-Path -LiteralPath $keyFile -PathType Leaf)) {
	throw 'gcloud configure: the service account key file is not readable'
}

Write-Host 'Activating Google Cloud service account'
$env:CLOUDSDK_CORE_DISABLE_PROMPTS = '1'
& $gcloud auth activate-service-account "--key-file=$keyFile" --quiet
if ($LASTEXITCODE -ne 0) {
	throw "gcloud configure: service account activation failed with exit code $LASTEXITCODE"
}
Write-Host 'Google Cloud service account activation complete'
