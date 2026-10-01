$ErrorActionPreference = 'Stop'

if (-not $env:APP_VERSION) {
	throw 'gitlab-runner install: APP_VERSION is required'
}
if ($env:APP_VERSION -notmatch '^\d+\.\d+\.\d+$') {
	throw "gitlab-runner install: invalid APP_VERSION: $env:APP_VERSION"
}
if (-not $env:ProgramFiles) {
	throw 'gitlab-runner install: ProgramFiles is required'
}

$architecture = switch ($env:PROCESSOR_ARCHITECTURE) {
	'AMD64' { 'amd64' }
	'ARM64' { 'arm64' }
	default { throw "gitlab-runner install: unsupported architecture $env:PROCESSOR_ARCHITECTURE" }
}

$downloads = if ($env:GITLAB_RUNNER_DOWNLOADS) {
	$env:GITLAB_RUNNER_DOWNLOADS
} else {
	'https://s3.dualstack.us-east-1.amazonaws.com/gitlab-runner-downloads'
}
$asset = "gitlab-runner-windows-$architecture.exe"
$base = "$downloads/v$($env:APP_VERSION)"
$root = Join-Path $env:ProgramFiles 'gitlab-runner'
$prefix = Join-Path $root $env:APP_VERSION
$current = Join-Path $root 'current'
$work = Join-Path ([System.IO.Path]::GetTempPath()) "gitlab-runner-$([guid]::NewGuid())"

try {
	New-Item -ItemType Directory -Path $work -Force | Out-Null
	$binary = Join-Path $work $asset
	Invoke-WebRequest -UseBasicParsing -Uri "$base/binaries/$asset" -OutFile $binary

	# Every release publishes an index listing each file with its SHA-256. The link
	# text is matched up to its closing tag so one asset cannot match a longer name
	# that starts the same way.
	$index = (Invoke-WebRequest -UseBasicParsing -Uri "$base/index.html").Content
	$pattern = "binaries/$([regex]::Escape($asset))</a></span>\s*" +
		'<span class="file_checksum">([0-9a-f]{64})</span>'
	$match = [regex]::Match($index, $pattern)
	if (-not $match.Success) {
		throw "gitlab-runner install: no published checksum for $asset in release v$($env:APP_VERSION)"
	}
	$expected = $match.Groups[1].Value
	$actual = (Get-FileHash -Algorithm SHA256 $binary).Hash.ToLowerInvariant()
	if ($actual -ne $expected) {
		throw "gitlab-runner install: checksum verification failed asset=$asset expected=$expected actual=$actual"
	}

	# Checked before anything is published: a binary that fails here must not be
	# left behind the `current` junction an already-working version owns.
	$versionOutput = & $binary --version | Out-String
	if ($LASTEXITCODE -ne 0 -or $versionOutput -notmatch [regex]::Escape($env:APP_VERSION)) {
		throw "gitlab-runner install: the downloaded runner does not report $($env:APP_VERSION): $versionOutput"
	}

	New-Item -ItemType Directory -Path $prefix -Force | Out-Null
	Copy-Item -LiteralPath $binary -Destination (Join-Path $prefix 'gitlab-runner.exe') -Force

	if (Test-Path -LiteralPath $current) {
		$item = Get-Item -LiteralPath $current -Force
		if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
			throw "gitlab-runner install: $current exists and is not a junction"
		}
		[IO.Directory]::Delete($current)
	}
	New-Item -ItemType Junction -Path $current -Target $prefix | Out-Null

	$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
	$entries = @($machinePath -split ';' | Where-Object { $_ })
	$normalized = @($entries | ForEach-Object { $_.TrimEnd('\') })
	if ($current.TrimEnd('\') -notin $normalized) {
		[Environment]::SetEnvironmentVariable(
			'Path',
			(@($entries) + $current) -join ';',
			'Machine'
		)
	}

	Write-Host "gitlab-runner install: installed version=$($env:APP_VERSION) dir=$prefix"
} finally {
	Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

# Nothing above registers the runner. A pool bake runs the install phase alone and
# snapshots the disk, so a runner created here would be shared by every clone of
# the image; start-gitlab-runner.ps1 creates it once per node.
