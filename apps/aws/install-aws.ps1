$ErrorActionPreference = 'Stop'

$existing = Get-Command aws -ErrorAction SilentlyContinue
if ($existing -and -not $env:APP_VERSION -and -not $env:AWS_CLI_FORCE_INSTALL) {
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
	$msiUrl = if ($env:APP_VERSION) {
		"https://awscli.amazonaws.com/AWSCLIV2-$($env:APP_VERSION).msi"
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
