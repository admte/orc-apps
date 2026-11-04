<#
.SYNOPSIS
Downloads the latest GitHub Actions runner release into .\github-runner. Registers nothing.

.DESCRIPTION
Install phase: downloads and unpacks the runner, and nothing else. It takes no url and no
token: the build is the latest public release, whichever credential the node later
registers with, and the runner updates itself from there.

.PARAMETER Arch
amd64 or arm64.
#>
[CmdletBinding()]
param(
	[string]$Arch = ''
)

$ErrorActionPreference = 'Stop'
# Windows PowerShell on Server 2016 offers only TLS 1.0 and 1.1 by default, and
# GitHub accepts nothing older than TLS 1.2.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# The name GitHub's runner archives use for this architecture.
function Get-RunnerArch($arch) {
	switch -CaseSensitive ($arch) {
		'amd64' { return 'x64' }
		'arm64' { return 'arm64' }
		'' { throw 'github-runner install: -Arch is required' }
		default { throw "github-runner install: unsupported architecture $arch" }
	}
}

# Selects this target's archive from GitHub's public release metadata for the
# runner, in the shape the downloads API returns. The checksum is the asset's own
# digest, else the one the release notes carry between BEGIN/END SHA markers, else
# empty.
function Select-ReleaseAsset($release, $arch) {
	$version = $release.tag_name.TrimStart('v')
	$name = "actions-runner-win-$arch-$version.zip"
	$asset = $release.assets | Where-Object { $_.name -eq $name } | Select-Object -First 1
	if (-not $asset) { return $null }
	$checksum = ''
	if ($asset.digest -and $asset.digest.StartsWith('sha256:')) {
		$checksum = $asset.digest.Substring('sha256:'.Length)
	} elseif ($release.body -match "<!-- BEGIN SHA win-$arch -->\s*([0-9a-fA-F]{64})\s*<!-- END SHA") {
		$checksum = $Matches[1]
	}
	return [pscustomobject]@{
		filename        = $name
		download_url    = $asset.browser_download_url
		sha256_checksum = $checksum
	}
}

$runnerArch = Get-RunnerArch $Arch
$workDir = 'github-runner'

New-Item -ItemType Directory -Force -Path $workDir | Out-Null

# The runner self-updates afterward, so no version pinning. GitHub's public release
# metadata needs no credential, which is why install takes none.
$release = Invoke-RestMethod -Headers @{ Accept = 'application/vnd.github+json' } `
	-Uri 'https://api.github.com/repos/actions/runner/releases/latest'
$selected = Select-ReleaseAsset $release $runnerArch
if (-not $selected) { throw "no runner download for win/$runnerArch" }
$archive = $selected.filename
$tmp = New-Item -ItemType Directory -Force -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString()))

try {
	$zip = Join-Path $tmp.FullName $archive
	Write-Host "Downloading GitHub Actions runner ($archive)"
	Invoke-WebRequest -UseBasicParsing -Uri $selected.download_url -OutFile $zip
	if ($selected.sha256_checksum) {
		$actual = (Get-FileHash -Algorithm SHA256 -Path $zip).Hash.ToLowerInvariant()
		if ($actual -ne $selected.sha256_checksum.ToLowerInvariant()) {
			throw "checksum mismatch for ${archive}: expected $($selected.sha256_checksum), got $actual"
		}
		Write-Host 'Checksum verified'
	} else {
		Write-Host "GitHub did not publish a checksum for $archive; skipping verification"
	}
	Expand-Archive -Force -Path $zip -DestinationPath $workDir
} finally {
	Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

# Nothing above may create node identity. A pool bake runs the install phase alone
# and snapshots the disk, so anything written here is shared by every clone of the
# image: registering would leave a dead runner on GitHub for a builder that no
# longer exists, and `config.cmd` writes `.runner` and `.credentials` — the
# runner's own auth material — into the snapshot. The registration is
# start-github-runner.ps1's, once per node.
Write-Host "github-runner install: complete dir=$workDir"
