$ErrorActionPreference = 'Stop'

$existing = Get-Command jf -ErrorAction SilentlyContinue
if ($existing -and -not $env:JFROG_CLI_FORCE_INSTALL) {
	& $existing.Source --version
	exit 0
}
if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
	throw "jfrog install: unsupported architecture $env:PROCESSOR_ARCHITECTURE"
}

$version = if ($env:JFROG_CLI_VERSION) { $env:JFROG_CLI_VERSION } else { '[RELEASE]' }
$url = "https://releases.jfrog.io/artifactory/jfrog-cli/v2-jf/$version/jfrog-cli-windows-amd64/jf.exe"
$installDir = if ($env:JFROG_CLI_INSTALL_DIR) {
	$env:JFROG_CLI_INSTALL_DIR
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
