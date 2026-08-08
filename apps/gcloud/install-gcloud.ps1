$ErrorActionPreference = 'Stop'

$existing = Get-Command gcloud -ErrorAction SilentlyContinue
if ($existing -and -not $env:GCLOUD_CLI_FORCE_INSTALL) {
	& $existing.Source version
	if ($LASTEXITCODE -ne 0) {
		throw "gcloud install: existing CLI failed with exit code $LASTEXITCODE"
	}
	exit 0
}
if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
	throw "gcloud install: unsupported architecture $env:PROCESSOR_ARCHITECTURE"
}

$installRoot = if ($env:GCLOUD_INSTALL_DIR) {
	$env:GCLOUD_INSTALL_DIR
} else {
	Join-Path $env:LOCALAPPDATA 'Google\Cloud SDK'
}
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "gcloud-$([guid]::NewGuid())"

try {
	New-Item -ItemType Directory -Path $tmp -Force | Out-Null
	$installer = Join-Path $tmp 'GoogleCloudSDKInstaller.exe'
	Write-Host 'Downloading Google Cloud CLI for windows/amd64'
	Invoke-WebRequest -UseBasicParsing `
		-Uri 'https://dl.google.com/dl/cloudsdk/channels/rapid/GoogleCloudSDKInstaller.exe' `
		-OutFile $installer

	$arguments = @(
		'/S',
		'/singleuser',
		'/noreporting',
		'/nostartmenu',
		'/nodesktop',
		"/D=$installRoot"
	)
	$process = Start-Process $installer -ArgumentList $arguments -Wait -PassThru
	if ($process.ExitCode -ne 0) {
		throw "gcloud install: installer failed with exit code $($process.ExitCode)"
	}

	$candidates = @(
		(Join-Path $installRoot 'google-cloud-sdk\bin\gcloud.cmd'),
		(Join-Path $installRoot 'bin\gcloud.cmd')
	)
	$gcloud = $candidates | Where-Object {
		Test-Path -LiteralPath $_ -PathType Leaf
	} | Select-Object -First 1
	if (-not $gcloud) {
		throw "gcloud install: executable was not found under $installRoot"
	}

	$binDir = Split-Path -Parent $gcloud
	$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
	$pathEntries = @($userPath -split ';' | Where-Object { $_ })
	if ($binDir -notin $pathEntries) {
		[Environment]::SetEnvironmentVariable(
			'Path',
			(@($pathEntries) + $binDir) -join ';',
			'User'
		)
	}

	& $gcloud version
	if ($LASTEXITCODE -ne 0) {
		throw "gcloud install: installed CLI failed with exit code $LASTEXITCODE"
	}
} finally {
	Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
