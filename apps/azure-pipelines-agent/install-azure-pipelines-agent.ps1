$ErrorActionPreference = 'Stop'

$releases = if ($env:AZP_RELEASES_API) {
	$env:AZP_RELEASES_API
} else {
	'https://api.github.com/repos/microsoft/azure-pipelines-agent/releases/latest'
}
$downloads = if ($env:AZP_DOWNLOADS) { $env:AZP_DOWNLOADS } else { 'https://download.agent.dev.azure.com/agent' }

$architecture = switch ($env:PROCESSOR_ARCHITECTURE) {
	'AMD64' { 'x64' }
	'ARM64' { 'arm64' }
	default { throw "azure-pipelines-agent install: unsupported architecture $env:PROCESSOR_ARCHITECTURE" }
}

$workDir = Join-Path (Get-Location) 'azure-pipelines-agent'
$work = Join-Path ([System.IO.Path]::GetTempPath()) "azp-$([guid]::NewGuid())"

try {
	New-Item -ItemType Directory -Path $work -Force | Out-Null

	# The release the project currently publishes. The agent updates itself
	# afterwards, so this is a starting point rather than a pin.
	$release = Invoke-RestMethod -UseBasicParsing -Uri $releases `
		-Headers @{ Accept = 'application/vnd.github+json' }
	$version = $release.tag_name -replace '^v', ''
	if ($version -notmatch '^\d+\.\d+\.\d+$') {
		throw "azure-pipelines-agent install: unexpected agent version: $version"
	}

	$asset = "vsts-agent-win-$architecture-$version.zip"
	# Each release body carries a table of every package with its SHA-256. The row
	# is matched on the full file name, which no other row contains as a substring.
	$checksum = $null
	foreach ($line in ($release.body -split "`n")) {
		if ($line.Contains($asset)) {
			foreach ($cell in ($line -split '\|')) {
				$cell = $cell.Trim()
				if ($cell -match '^[0-9a-f]{64}$') { $checksum = $cell; break }
			}
		}
		if ($checksum) { break }
	}
	if (-not $checksum) {
		throw "azure-pipelines-agent install: no published checksum for $asset in release v$version"
	}

	Write-Host "azure-pipelines-agent install: downloading the agent version=$version asset=$asset"
	$archive = Join-Path $work $asset
	Invoke-WebRequest -UseBasicParsing -Uri "$downloads/$version/$asset" -OutFile $archive
	$actual = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant()
	if ($actual -ne $checksum) {
		throw "azure-pipelines-agent install: checksum verification failed asset=$asset expected=$checksum actual=$actual"
	}

	New-Item -ItemType Directory -Path $workDir -Force | Out-Null
	Expand-Archive -LiteralPath $archive -DestinationPath $workDir -Force
	if (-not (Test-Path -LiteralPath (Join-Path $workDir 'config.cmd') -PathType Leaf)) {
		throw "azure-pipelines-agent install: config.cmd is missing from $asset"
	}

	Write-Host "azure-pipelines-agent install: installed version=$version dir=$workDir"
} finally {
	Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

# Nothing above registers the agent. A pool bake runs the install phase alone and
# snapshots the disk, so a registration made here would be shared by every clone
# of the image, along with the `.credentials` config.cmd writes;
# start-azure-pipelines-agent.ps1 registers once per node.
