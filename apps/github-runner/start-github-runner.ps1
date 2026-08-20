$ErrorActionPreference = 'Stop'

$workDir = 'github-runner'
$runScript = Join-Path $workDir 'run.cmd'
if (-not (Test-Path $runScript)) {
	throw "github-runner start: $runScript not found; run install first"
}

Push-Location $workDir
try {
	& .\run.cmd
	exit $LASTEXITCODE
} finally {
	Pop-Location
}
