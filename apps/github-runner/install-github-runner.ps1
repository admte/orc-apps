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

function Get-RunnerArch {
	switch ($env:PROCESSOR_ARCHITECTURE) {
		'AMD64' { return 'x64' }
		'ARM64' { return 'arm64' }
		default { throw "unsupported architecture $env:PROCESSOR_ARCHITECTURE" }
	}
}

$githubToken = Get-Token
$apiPath = Get-GitHubApiPath
$workDir = if ($env:WORK_DIR) { $env:WORK_DIR } else { 'github-runner' }
$runnerName = if ($env:RUNNER_NAME) { $env:RUNNER_NAME } else { $env:COMPUTERNAME }
$labels = if ($env:LABELS) { $env:LABELS } else { '' }

New-Item -ItemType Directory -Force -Path $workDir | Out-Null

$latest = Invoke-RestMethod -Headers @{ Accept = 'application/vnd.github+json' } `
	-Uri 'https://api.github.com/repos/actions/runner/releases/latest'
$version = $latest.tag_name.TrimStart('v')
$archive = "actions-runner-win-$(Get-RunnerArch)-$version.zip"
$url = "https://github.com/actions/runner/releases/download/v$version/$archive"
$tmp = New-Item -ItemType Directory -Force -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString()))

try {
	$zip = Join-Path $tmp.FullName $archive
	Write-Host "Downloading GitHub Actions runner $version ($archive)"
	Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip
	Expand-Archive -Force -Path $zip -DestinationPath $workDir
} finally {
	Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

$registration = Invoke-RestMethod -Method Post `
	-Headers @{ Accept = 'application/vnd.github+json'; Authorization = "token $githubToken" } `
	-Uri "https://api.github.com/$apiPath/actions/runners/registration-token"

$configArgs = @('--name', $runnerName, '--url', $env:URL, '--token', $registration.token, '--unattended', '--replace')
if ($labels) {
	$configArgs += @('--labels', $labels)
}

Push-Location $workDir
try {
	& .\config.cmd @configArgs
	if ($LASTEXITCODE -ne 0) {
		throw "config.cmd failed with exit code $LASTEXITCODE"
	}
} finally {
	Pop-Location
}
