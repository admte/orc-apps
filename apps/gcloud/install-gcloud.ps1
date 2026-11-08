<#
.SYNOPSIS
Installs the latest Google Cloud CLI for every user of the machine.

.DESCRIPTION
Unpacks Google's Windows archive, which bundles its own Python, and puts its bin
directory on the machine PATH. Leaves a gcloud command that is already on PATH as it is.

.PARAMETER Force
Install even when gcloud is already on PATH.

.PARAMETER InstallDir
Where the SDK is unpacked (default: Google\Cloud SDK under Program Files).
#>
[CmdletBinding()]
param(
	[switch]$Force,
	[string]$InstallDir = ''
)

$ErrorActionPreference = 'Stop'
# Progress rendering slows downloads and archive expansion many times over.
$ProgressPreference = 'SilentlyContinue'

$existing = Get-Command gcloud -ErrorAction SilentlyContinue
if ($existing -and -not $Force) {
	& $existing.Source version
	if ($LASTEXITCODE -ne 0) {
		throw "gcloud install: existing CLI failed with exit code $LASTEXITCODE"
	}
	exit 0
}
if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
	throw "gcloud install: unsupported architecture $env:PROCESSOR_ARCHITECTURE"
}
if (-not $InstallDir -and -not $env:ProgramFiles) {
	throw 'gcloud install: ProgramFiles is required'
}

$installRoot = if ($InstallDir) {
	$InstallDir
} else {
	Join-Path $env:ProgramFiles 'Google\Cloud SDK'
}
$sdk = Join-Path $installRoot 'google-cloud-sdk'
$binDir = Join-Path $sdk 'bin'
$gcloud = Join-Path $binDir 'gcloud.cmd'
$archiveName = 'google-cloud-cli-windows-x86_64-bundled-python.zip'
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "gcloud-$([guid]::NewGuid())"

try {
	New-Item -ItemType Directory -Path $tmp -Force | Out-Null
	$archive = Join-Path $tmp $archiveName
	Write-Host 'Downloading Google Cloud CLI for windows/amd64'
	Invoke-WebRequest -UseBasicParsing `
		-Uri "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/$archiveName" `
		-OutFile $archive

	$unpacked = Join-Path $tmp 'unpacked'
	New-Item -ItemType Directory -Path $unpacked -Force | Out-Null
	# tar.exe unpacks the SDK's deep tree far faster than Expand-Archive, which
	# also stops at MAX_PATH; it ships with Windows 10 and Server 2019 onwards.
	$tar = Join-Path $env:SystemRoot 'System32\tar.exe'
	if (Test-Path -LiteralPath $tar -PathType Leaf) {
		& $tar -xf $archive -C $unpacked
		if ($LASTEXITCODE -ne 0) {
			throw "gcloud install: unpacking $archiveName failed with exit code $LASTEXITCODE"
		}
	} else {
		Expand-Archive -LiteralPath $archive -DestinationPath $unpacked
	}
	$source = Join-Path $unpacked 'google-cloud-sdk'
	if (-not (Test-Path -LiteralPath (Join-Path $source 'bin\gcloud.cmd') -PathType Leaf)) {
		throw "gcloud install: gcloud is missing from $archiveName"
	}

	New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
	Remove-Item -LiteralPath $sdk -Recurse -Force -ErrorAction SilentlyContinue
	Move-Item -LiteralPath $source -Destination $sdk

	$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
	$entries = @($machinePath -split ';' | Where-Object { $_ })
	if ($binDir -notin $entries) {
		[Environment]::SetEnvironmentVariable(
			'Path',
			(@($entries) + $binDir) -join ';',
			'Machine'
		)
	}

	$env:CLOUDSDK_CORE_DISABLE_PROMPTS = '1'
	& $gcloud version
	if ($LASTEXITCODE -ne 0) {
		throw "gcloud install: installed CLI failed with exit code $LASTEXITCODE"
	}
} finally {
	Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
