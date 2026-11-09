<#
.SYNOPSIS
Installs uv, uvx and uvw for every user of the machine.

.DESCRIPTION
Installs into %ProgramFiles%\uv and adds that directory to the machine PATH. With -Version it
installs that release; without it, the latest release, and leaves a uv already installed there
as it is.

.PARAMETER Version
uv release to install, e.g. 0.4.20.
#>
[CmdletBinding()]
param(
	[string]$Version = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if (-not $env:ProgramFiles) {
	throw 'uv install: ProgramFiles is required'
}
if ($Version -and $Version -notmatch '^\d+\.\d+\.\d+$') {
	throw "uv install: invalid version: $Version"
}
$target = switch ($env:PROCESSOR_ARCHITECTURE) {
	'AMD64' { 'x86_64-pc-windows-msvc' }
	'ARM64' { 'aarch64-pc-windows-msvc' }
	default { throw "uv install: unsupported architecture $env:PROCESSOR_ARCHITECTURE" }
}

$installDir = Join-Path $env:ProgramFiles 'uv'
$uv = Join-Path $installDir 'uv.exe'
$programs = @('uv.exe', 'uvx.exe', 'uvw.exe')

function Add-MachinePath([string]$dir) {
	$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
	$entries = @($machinePath -split ';' | Where-Object { $_ })
	$present = $entries | Where-Object { $_.TrimEnd('\') -eq $dir.TrimEnd('\') }
	if (-not $present) {
		[Environment]::SetEnvironmentVariable('Path', (@($entries) + $dir) -join ';', 'Machine')
	}
}

if (-not $Version -and (Test-Path -LiteralPath $uv -PathType Leaf)) {
	Add-MachinePath $installDir
	& $uv --version
	if ($LASTEXITCODE -ne 0) {
		throw "uv install: $uv --version failed"
	}
	exit 0
}

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor
	[Net.SecurityProtocolType]::Tls12

$asset = "uv-$target.zip"
if ($Version) {
	$base = "https://github.com/astral-sh/uv/releases/download/$Version"
} else {
	$base = 'https://github.com/astral-sh/uv/releases/latest/download'
}
$work = Join-Path ([System.IO.Path]::GetTempPath()) "uv-$([guid]::NewGuid())"

try {
	New-Item -ItemType Directory -Path $work -Force | Out-Null
	$archive = Join-Path $work $asset
	$sum = Join-Path $work "$asset.sha256"

	Write-Host "Downloading $asset from $base"
	Invoke-WebRequest -UseBasicParsing -Uri "$base/$asset" -OutFile $archive
	Invoke-WebRequest -UseBasicParsing -Uri "$base/$asset.sha256" -OutFile $sum

	$expected = ((Get-Content -LiteralPath $sum -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
	if ($expected -notmatch '^[0-9a-f]{64}$') {
		throw "uv install: checksum for $asset was not published"
	}
	$actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
	if ($actual -ne $expected) {
		throw "uv install: checksum verification failed for $asset"
	}

	$unpacked = Join-Path $work 'unpacked'
	Expand-Archive -LiteralPath $archive -DestinationPath $unpacked
	foreach ($program in $programs) {
		if (-not (Test-Path -LiteralPath (Join-Path $unpacked $program) -PathType Leaf)) {
			throw "uv install: $program is missing from $asset"
		}
	}

	New-Item -ItemType Directory -Path $installDir -Force | Out-Null
	foreach ($program in $programs) {
		Copy-Item -LiteralPath (Join-Path $unpacked $program) -Destination $installDir -Force
	}
} finally {
	Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Add-MachinePath $installDir

$installed = & $uv --version
if ($LASTEXITCODE -ne 0) {
	throw "uv install: $uv --version failed"
}
if ($Version -and $installed -notmatch "^uv $([regex]::Escape($Version))(\s|$)") {
	throw "uv install: installed version '$installed' does not match $Version"
}
Write-Host $installed
