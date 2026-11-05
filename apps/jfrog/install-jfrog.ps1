<#
.SYNOPSIS
Installs the JFrog CLI (jf.exe) for the current user.

.DESCRIPTION
Without -Version it installs the latest release, and leaves a jf command that is
already on PATH as it is.

.PARAMETER Version
JFrog CLI release to install, e.g. 2.70.0.

.PARAMETER Force
Install even when jf is already on PATH.

.PARAMETER InstallDir
Where jf.exe is installed (default: Programs\JFrog under LOCALAPPDATA).
#>
[CmdletBinding()]
param(
	[string]$Version = '',
	[switch]$Force,
	[string]$InstallDir = ''
)

$ErrorActionPreference = 'Stop'

$existing = Get-Command jf -ErrorAction SilentlyContinue
if ($existing -and -not $Version -and -not $Force) {
	& $existing.Source --version
	exit 0
}
if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
	throw "jfrog install: unsupported architecture $env:PROCESSOR_ARCHITECTURE"
}

$release = if ($Version) { $Version } else { '[RELEASE]' }
$url = "https://releases.jfrog.io/artifactory/jfrog-cli/v2-jf/$release/jfrog-cli-windows-amd64/jf.exe"
$installDir = if ($InstallDir) {
	$InstallDir
} else {
	Join-Path $env:LOCALAPPDATA 'Programs\JFrog'
}
$jf = Join-Path $installDir 'jf.exe'

New-Item -ItemType Directory -Path $installDir -Force | Out-Null
Write-Host 'Downloading JFrog CLI for windows/amd64'
Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $jf

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$pathEntries = @($userPath -split ';' | Where-Object { $_ })
if ($installDir -notin $pathEntries) {
	[Environment]::SetEnvironmentVariable(
		'Path',
		(@($pathEntries) + $installDir) -join ';',
		'User'
	)
}

& $jf --version
