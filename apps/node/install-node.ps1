<#
.SYNOPSIS
Installs one Node.js release and puts it on the machine PATH.

.PARAMETER Version
Node.js release, e.g. 20.17.0. Defaults to the newest release nodejs.org
publishes.
#>
[CmdletBinding()]
param(
	[string]$Version = ''
)

$ErrorActionPreference = 'Stop'

# PowerShell 5.1 redraws the download progress bar on every block it reads,
# which on a one-core node costs more than the transfer itself.
$ProgressPreference = 'SilentlyContinue'

if (-not $env:ProgramFiles) {
	throw 'node install: ProgramFiles is required'
}

if (-not $Version) {
	# The version arrives empty when the request resolved to the implicit
	# `default` tag. index.json lists the releases, newest first.
	try {
		$index = Invoke-RestMethod -UseBasicParsing -Uri 'https://nodejs.org/dist/index.json'
	} catch {
		throw "node install: could not read the newest release from nodejs.org: $($_.Exception.Message)"
	}
	# The list carries prereleases too, so take the newest that is x.y.z.
	$Version = [string] ((@($index) |
		Where-Object { $_.version -match '^v\d+\.\d+\.\d+$' } |
		Select-Object -First 1).version)
	if (-not $Version) { throw 'node install: the release list names no final version' }
	Write-Host "node install: no version was requested; taking the newest release, $($Version -replace '^v', '')"
}

$requested = $Version
$version = $requested.TrimStart('v')
if ($version -notmatch '^\d+\.\d+\.\d+$') {
	throw "node install: invalid version: $requested"
}
$architecture = switch ($env:PROCESSOR_ARCHITECTURE) {
	'AMD64' { 'x64' }
	'ARM64' { 'arm64' }
	default { throw "node install: unsupported architecture $env:PROCESSOR_ARCHITECTURE" }
}
$asset = "node-v$version-win-$architecture.zip"
$base = "https://nodejs.org/dist/v$version"
$root = Join-Path $env:ProgramFiles 'node'
$prefix = Join-Path $root $version
$current = Join-Path $root 'current'

function Set-Exposure {
	New-Item -ItemType Directory -Path $root -Force | Out-Null
	if (Test-Path -LiteralPath $current) {
		$item = Get-Item -LiteralPath $current -Force
		if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
			throw "node install: $current exists and is not a junction"
		}
		$target = [IO.Path]::GetFullPath([string] $item.Target).TrimEnd('\')
		if ($target -ne [IO.Path]::GetFullPath($prefix).TrimEnd('\')) {
			[IO.Directory]::Delete($current)
			New-Item -ItemType Junction -Path $current -Target $prefix | Out-Null
		}
	} else {
		New-Item -ItemType Junction -Path $current -Target $prefix | Out-Null
	}

	$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
	$entries = @($machinePath -split ';' | Where-Object { $_ })
	if ($current -notin $entries) {
		[Environment]::SetEnvironmentVariable(
			'Path',
			(@($entries) + $current) -join ';',
			'Machine'
		)
	}
}

function Get-Reported($exe) {
	if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { return $null }
	$previous = $ErrorActionPreference
	$ErrorActionPreference = 'Continue'
	try {
		$out = (& $exe --version 2>&1 | Out-String -Width 4096).Trim()
		if ($LASTEXITCODE -eq 0) { return $out }
		return $null
	} finally {
		$ErrorActionPreference = $previous
	}
}

# The pool image is baked straight after this phase, and on Windows every node
# rebuilt from that image runs the phase again on a disk that already carries
# the release. Without this check each node downloads and unpacks it a second
# time.
$existing = Get-Reported (Join-Path $prefix 'node.exe')
if ($existing -and ($existing -eq "v$version" -or $existing.StartsWith("v$version-"))) {
	Set-Exposure
	Write-Host "node install: node $version is already installed"
	exit 0
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) "node-$([guid]::NewGuid())"

try {
	New-Item -ItemType Directory -Path $work -Force | Out-Null
	$archive = Join-Path $work $asset
	$sums = Join-Path $work 'SHASUMS256.txt'
	Invoke-WebRequest -UseBasicParsing -Uri "$base/$asset" -OutFile $archive
	Invoke-WebRequest -UseBasicParsing -Uri "$base/SHASUMS256.txt" -OutFile $sums

	$line = Get-Content $sums |
		Where-Object { $_ -match "^[0-9a-fA-F]{64}\s+\*?$([regex]::Escape($asset))$" } |
		Select-Object -First 1
	if (-not $line) {
		throw "node install: checksum for $asset was not published"
	}
	$expected = ($line -split '\s+')[0].ToLowerInvariant()
	$actual = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant()
	if ($actual -ne $expected) {
		throw "node install: checksum verification failed for $asset"
	}

	$unpacked = Join-Path $work 'unpacked'
	New-Item -ItemType Directory -Path $unpacked -Force | Out-Null
	# tar.exe, not Expand-Archive: the archive holds thousands of files, which
	# the cmdlet writes one at a time on PowerShell 5.1.
	$tar = Get-Command tar.exe -ErrorAction SilentlyContinue
	if ($tar) {
		& $tar.Source -xf $archive -C $unpacked
		if ($LASTEXITCODE -ne 0) { throw "node install: could not unpack $asset" }
	} else {
		Expand-Archive -LiteralPath $archive -DestinationPath $unpacked
	}
	$source = Join-Path $unpacked "node-v$version-win-$architecture"
	if (-not (Test-Path -LiteralPath (Join-Path $source 'node.exe') -PathType Leaf)) {
		throw "node install: node.exe is missing from $asset"
	}

	New-Item -ItemType Directory -Path $root -Force | Out-Null
	Remove-Item -LiteralPath $prefix -Recurse -Force -ErrorAction SilentlyContinue
	Move-Item -LiteralPath $source -Destination $prefix

	Set-Exposure

	$actualVersion = & (Join-Path $current 'node.exe') --version
	$reported = $actualVersion.Trim()
	if ($LASTEXITCODE -ne 0 -or
		($reported -ne "v$version" -and -not $reported.StartsWith("v$version-"))) {
		throw "node install: installed version '$actualVersion' does not match $version"
	}
} finally {
	Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
