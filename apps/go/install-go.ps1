<#
.SYNOPSIS
Installs one Go release and puts it on the machine PATH.

.PARAMETER Version
Go release, e.g. 1.22.5 (default: the latest stable release).
#>
[CmdletBinding()]
param(
	[string]$Version = ''
)

$ErrorActionPreference = 'Stop'
# Progress rendering slows downloads and archive expansion many times over.
$ProgressPreference = 'SilentlyContinue'

if (-not $env:ProgramFiles) {
	throw 'go install: ProgramFiles is required'
}

$releases = Invoke-RestMethod -UseBasicParsing -Uri 'https://go.dev/dl/?mode=json&include=all'
$requested = $Version
if (-not $requested) {
	# The release list is newest first.
	$requested = @($releases | Where-Object { $_.stable }) |
		Select-Object -First 1 -ExpandProperty version
	if (-not $requested) {
		throw 'go install: could not determine the latest Go release'
	}
}
$version = $requested -replace '^go', ''
if ($version -notmatch '^\d+\.\d+(\.\d+)?$') {
	throw "go install: invalid version: $requested"
}
$architecture = switch ($env:PROCESSOR_ARCHITECTURE) {
	'AMD64' { 'amd64' }
	'ARM64' { 'arm64' }
	default { throw "go install: unsupported architecture $env:PROCESSOR_ARCHITECTURE" }
}
$asset = "go$version.windows-$architecture.zip"
$root = Join-Path $env:ProgramFiles 'go'
$prefix = Join-Path $root $version
$current = Join-Path $root 'current'
$pathEntry = Join-Path $current 'bin'

function Set-Exposure {
	New-Item -ItemType Directory -Path $root -Force | Out-Null
	if (Test-Path -LiteralPath $current) {
		$item = Get-Item -LiteralPath $current -Force
		if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
			throw "go install: $current exists and is not a junction"
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
	if ($pathEntry -notin $entries) {
		[Environment]::SetEnvironmentVariable(
			'Path',
			(@($entries) + $pathEntry) -join ';',
			'Machine'
		)
	}
}

function Get-Reported($exe) {
	if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { return $null }
	$previous = $ErrorActionPreference
	$ErrorActionPreference = 'Continue'
	try {
		$out = (& $exe version 2>&1 | ForEach-Object { "$_" } | Out-String -Width 4096).Trim()
		if ($LASTEXITCODE -eq 0) { return $out }
		return $null
	} finally {
		$ErrorActionPreference = $previous
	}
}

# The pool image is baked straight after this phase, and every node is rebuilt
# from that image. Without this check each node downloads and unpacks a release
# the disk already carries, about a quarter of an hour on Windows.
$existing = Get-Reported (Join-Path $prefix 'bin\go.exe')
if ($existing -and $existing -match " go$([regex]::Escape($version)) ") {
	Set-Exposure
	Write-Host "go install: go $version is already installed"
	exit 0
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) "go-$([guid]::NewGuid())"

try {
	New-Item -ItemType Directory -Path $work -Force | Out-Null
	$release = $releases | Where-Object { $_.version -eq "go$version" } | Select-Object -First 1
	$file = $release.files | Where-Object {
		$_.filename -eq $asset -and $_.kind -eq 'archive'
	} | Select-Object -First 1
	if (-not $file -or -not $file.sha256) {
		throw "go install: checksum for $asset was not published"
	}

	$archive = Join-Path $work $asset
	Invoke-WebRequest -UseBasicParsing -Uri "https://go.dev/dl/$asset" -OutFile $archive
	$actual = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant()
	if ($actual -ne $file.sha256.ToLowerInvariant()) {
		throw "go install: checksum verification failed for $asset"
	}

	$unpacked = Join-Path $work 'unpacked'
	New-Item -ItemType Directory -Path $unpacked -Force | Out-Null
	# tar.exe, not Expand-Archive: the archive holds some thirteen thousand
	# files, which the cmdlet writes one at a time on PowerShell 5.1.
	$tar = Get-Command tar.exe -ErrorAction SilentlyContinue
	if ($tar) {
		& $tar.Source -xf $archive -C $unpacked
		if ($LASTEXITCODE -ne 0) { throw "go install: could not unpack $asset" }
	} else {
		Expand-Archive -LiteralPath $archive -DestinationPath $unpacked
	}
	$source = Join-Path $unpacked 'go'
	if (-not (Test-Path -LiteralPath (Join-Path $source 'bin\go.exe') -PathType Leaf)) {
		throw "go install: go.exe is missing from $asset"
	}

	New-Item -ItemType Directory -Path $root -Force | Out-Null
	Remove-Item -LiteralPath $prefix -Recurse -Force -ErrorAction SilentlyContinue
	Move-Item -LiteralPath $source -Destination $prefix

	Set-Exposure

	$actualVersion = & (Join-Path $pathEntry 'go.exe') version
	if ($LASTEXITCODE -ne 0 -or $actualVersion -notmatch " go$([regex]::Escape($version)) ") {
		throw "go install: installed version '$actualVersion' does not match $version"
	}
} finally {
	Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
