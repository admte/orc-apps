$ErrorActionPreference = 'Stop'

if (-not $env:APP_VERSION -and (Get-Command uv -ErrorAction SilentlyContinue)) {
	uv --version
	exit 0
}

if ($env:APP_VERSION) {
	$archive = 'uv-x86_64-pc-windows-msvc.zip'
	$url = "https://github.com/astral-sh/uv/releases/download/$($env:APP_VERSION)/$archive"
	$installDir = Join-Path $env:USERPROFILE '.local\bin'
	$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "uv-$([guid]::NewGuid())"
	try {
		New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
		$archivePath = Join-Path $tempDir $archive

		Write-Host "Downloading uv $($env:APP_VERSION) for windows/amd64"
		Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $archivePath

		$unpacked = Join-Path $tempDir 'unpacked'
		Expand-Archive -Path $archivePath -DestinationPath $unpacked
		New-Item -ItemType Directory -Path $installDir -Force | Out-Null
		Copy-Item -Path (Join-Path $unpacked 'uv.exe') -Destination $installDir -Force
		Copy-Item -Path (Join-Path $unpacked 'uvx.exe') -Destination $installDir -Force

		$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
		$pathEntries = @($userPath -split ';' | Where-Object { $_ })
		if ($installDir -notin $pathEntries) {
			[Environment]::SetEnvironmentVariable(
				'Path',
				(@($pathEntries) + $installDir) -join ';',
				'User'
			)
		}

		& (Join-Path $installDir 'uv.exe') --version
	} finally {
		if (Test-Path $tempDir) {
			Remove-Item -Path $tempDir -Recurse -Force
		}
	}
	exit 0
}

Invoke-Expression (Invoke-RestMethod -Uri 'https://astral.sh/uv/install.ps1')

if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
	Write-Error 'uv not found after installation'
}

uv --version
