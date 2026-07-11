$ErrorActionPreference = 'Stop'

function Get-Token {
	if ($env:TOKEN_FILE) {
		return (Get-Content -Raw -LiteralPath $env:TOKEN_FILE).Trim()
	}
	if ($env:TOKEN) {
		return $env:TOKEN.Trim()
	}
	throw 'TOKEN_FILE or TOKEN is required'
}

function Get-GitHubApiPath {
	if (-not $env:URL -or -not $env:URL.StartsWith('https://github.com/')) {
		throw 'URL must start with https://github.com/'
	}
	$path = $env:URL.Substring('https://github.com/'.Length).TrimEnd('/')
	if ($path.EndsWith('.git')) {
		$path = $path.Substring(0, $path.Length - 4)
	}
	$parts = $path.Split('/', 2)
	if (-not $parts[0]) {
		throw 'GitHub owner is required'
	}
	if ($parts.Length -eq 2 -and $parts[1]) {
		return "repos/$($parts[0])/$($parts[1])"
	}
	return "orgs/$($parts[0])"
}

$workDir = if ($env:WORK_DIR) { $env:WORK_DIR } else { 'github-runner' }
$configScript = Join-Path $workDir 'config.cmd'
if (-not (Test-Path $configScript)) {
	Write-Host "github-runner drain: $configScript not found; nothing to remove"
	exit 0
}

$githubToken = Get-Token
$apiPath = Get-GitHubApiPath
$remove = Invoke-RestMethod -Method Post `
	-Headers @{ Accept = 'application/vnd.github+json'; Authorization = "token $githubToken" } `
	-Uri "https://api.github.com/$apiPath/actions/runners/remove-token"

Push-Location $workDir
try {
	& .\config.cmd remove --token $remove.token
	if ($LASTEXITCODE -ne 0) {
		throw "config.cmd remove failed with exit code $LASTEXITCODE"
	}
} finally {
	Pop-Location
}
