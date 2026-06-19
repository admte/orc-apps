$ErrorActionPreference = 'Stop'

if (Get-Command uv -ErrorAction SilentlyContinue) {
	uv --version
	exit 0
}

Invoke-Expression (Invoke-RestMethod -Uri 'https://astral.sh/uv/install.ps1')

if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
	Write-Error 'uv not found after installation'
}

uv --version
