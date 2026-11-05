$ErrorActionPreference = 'Stop'

if (-not $env:ProgramFiles) {
	throw 'go install: ProgramFiles is required'
}

# Progress on stdout: the node log renders an install's stderr as warnings.
function Note($message) { Write-Host "go install: $message" }

# PowerShell 5.1 redraws the download progress bar on every block it reads,
# which on a node costs more than the transfer.
$ProgressPreference = 'SilentlyContinue'

$architecture = switch ($env:PROCESSOR_ARCHITECTURE) {
	'AMD64' { 'amd64' }
	'ARM64' { 'arm64' }
	default { throw "go install: unsupported architecture $env:PROCESSOR_ARCHITECTURE" }
}

$version = $env:APP_VERSION -replace '^go', ''
if (-not $version) {
	# APP_VERSION arrives unset when the request resolved to the implicit
	# `default` tag. `?mode=json` lists the stable releases, newest first.
	Note 'no version was requested; taking the newest release'
	try {
		$stable = Invoke-RestMethod -UseBasicParsing -Uri 'https://go.dev/dl/?mode=json'
	} catch {
		throw "go install: could not read the newest release from go.dev: $($_.Exception.Message)"
	}
	$version = ([string] (@($stable)[0].version) -replace '^go', '')
	if (-not $version) { throw 'go install: the release list names no version' }
	Note "newest release is $version"
}
if ($version -notmatch '^\d+\.\d+(\.\d+)?$') {
	throw "go install: invalid version: $version"
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
		$out = (& $exe version 2>&1 | Out-String -Width 4096).Trim()
		if ($LASTEXITCODE -eq 0) { return $out }
		return $null
	} finally {
		$ErrorActionPreference = $previous
	}
}

# The pool image is baked straight after this phase and every node is rebuilt
# from that image, which runs the phase again on a disk that already carries the
# toolchain. Without this check each node repeats the install, about a quarter
# of an hour on Windows.
$existing = Get-Reported (Join-Path $prefix 'bin\go.exe')
if ($existing -and $existing -match " go$([regex]::Escape($version)) ") {
	Set-Exposure
	Note "go $version is already installed"
	exit 0
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) "go-$([guid]::NewGuid())"

try {
	New-Item -ItemType Directory -Path $work -Force | Out-Null
	$releases = Invoke-RestMethod -UseBasicParsing -Uri 'https://go.dev/dl/?mode=json&include=all'
	$release = $releases | Where-Object { $_.version -eq "go$version" } | Select-Object -First 1
	$file = $release.files | Where-Object {
		$_.filename -eq $asset -and $_.kind -eq 'archive'
	} | Select-Object -First 1
	if (-not $file -or -not $file.sha256) {
		throw "go install: checksum for $asset was not published"
	}

	Note "downloading $asset"
	$archive = Join-Path $work $asset
	Invoke-WebRequest -UseBasicParsing -Uri "https://go.dev/dl/$asset" -OutFile $archive
	$actual = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant()
	if ($actual -ne $file.sha256.ToLowerInvariant()) {
		throw "go install: checksum verification failed for $asset"
	}

	$unpacked = Join-Path $work 'unpacked'
	New-Item -ItemType Directory -Path $unpacked -Force | Out-Null
	# tar.exe, not Expand-Archive: the archive holds some thirteen thousand
	# files, which the cmdlet handles one at a time on PowerShell 5.1.
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

	$actualVersion = Get-Reported (Join-Path $prefix 'bin\go.exe')
	if (-not $actualVersion -or $actualVersion -notmatch " go$([regex]::Escape($version)) ") {
		throw "go install: installed version '$actualVersion' does not match $version"
	}
} finally {
	Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Note "go $version installed at $prefix"
