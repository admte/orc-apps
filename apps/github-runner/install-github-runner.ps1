$ErrorActionPreference = 'Stop'

# Returns the token value, or nothing when none was delivered: install needs a
# credential only to ask GitHub's downloads API, and has a public path without one.
function Get-Token {
	if ($env:TOKEN_FILE) {
		return (Get-Content -Raw -LiteralPath $env:TOKEN_FILE).Trim()
	}
	if ($env:TOKEN) {
		return $env:TOKEN.Trim()
	}
	return ''
}

# The token param holds either an operator's personal access token or a
# registration orc8r minted for this node, a JSON object. They are told apart by
# shape: a value whose first non-blank character is `{` is the minted credential.
function Test-Minted($value) {
	return [bool]($value -and $value.TrimStart().StartsWith('{'))
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

$githubToken = Get-Token
$workDir = 'github-runner'

New-Item -ItemType Directory -Force -Path $workDir | Out-Null

# The runner self-updates afterward, so no version pinning on either path.
$arch = Get-RunnerArch
if ($githubToken -and -not (Test-Minted $githubToken)) {
	# A personal access token: ask GitHub which runner build its service currently
	# wants for this registration target.
	$apiPath = Get-GitHubApiPath
	$downloads = Invoke-RestMethod -Headers @{
		Accept        = 'application/vnd.github+json'
		Authorization = "token $githubToken"
	} -Uri "https://api.github.com/$apiPath/actions/runners/downloads"
	$selected = $downloads | Where-Object { $_.os -eq 'win' -and $_.architecture -eq $arch } | Select-Object -First 1
} else {
	# A minted registration, or none delivered yet: install holds no API
	# credential, so it takes the latest release from GitHub's public metadata.
	Write-Host 'github-runner install: no API token; using the latest public runner release'
	$release = Invoke-RestMethod -Headers @{ Accept = 'application/vnd.github+json' } `
		-Uri 'https://api.github.com/repos/actions/runner/releases/latest'
	$selected = Select-ReleaseAsset $release $arch
}
if (-not $selected) { throw "no runner download for win/$arch" }
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
