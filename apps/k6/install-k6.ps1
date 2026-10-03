$ErrorActionPreference = 'Stop'

# Installs one k6 release under Program Files and exposes it through a `current`
# junction plus a single machine PATH entry — the shape go, java, node, trivy and syft
# use on Windows, so switching versions never rewrites the PATH.

function Fail($message) { throw "k6 install: $message" }
function Note($message) { Write-Host "k6 install: $message" }

if (-not $env:ProgramFiles) { Fail 'ProgramFiles is required' }
if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64' -and $env:PROCESSOR_ARCHITEW6432 -ne 'AMD64') {
	Fail "unsupported architecture $env:PROCESSOR_ARCHITECTURE"
}

# Windows PowerShell 5.1 leaves TLS at the machine default, which on older images can
# still be 1.0; GitHub requires 1.2.
[Net.ServicePointManager]::SecurityProtocol =
	[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$version = $env:APP_VERSION -replace '^v', ''
if (-not $version) {
	# APP_VERSION arrives unset when the request resolved to the implicit `default` tag.
	Note 'no version was requested; taking the newest release'
	try {
		$latest = Invoke-RestMethod -UseBasicParsing -Headers @{ 'User-Agent' = 'orc-k6' } `
			-Uri 'https://api.github.com/repos/grafana/k6/releases/latest'
	} catch {
		Fail "could not read the newest release from GitHub: $($_.Exception.Message)"
	}
	$version = ([string] $latest.tag_name) -replace '^v', ''
	Note "newest release is $version"
}
if ($version -notmatch '^\d+\.\d+\.\d+\z') { Fail "invalid version: $version" }

# The project's own naming: hyphens, and the version written with its leading "v" inside
# the file name. The release also carries an .msi beside the .zip; this takes the zip, so
# nothing is installed through Windows Installer behind the node's back.
$asset = "k6-v$version-windows-amd64.zip"
$sums = "k6-v$version-checksums.txt"
$base = "https://github.com/grafana/k6/releases/download/v$version"

$root = Join-Path $env:ProgramFiles 'k6'
$prefix = Join-Path $root $version
$current = Join-Path $root 'current'
$work = Join-Path ([IO.Path]::GetTempPath()) "k6-$([guid]::NewGuid())"

# Runs the binary and returns what it reports, or $null. Both spellings are tried. The
# preference is lowered because `2>&1` on a native command is a terminating error while
# it is Stop.
function Get-Reported($exe) {
	if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { return $null }
	$previous = $ErrorActionPreference
	$ErrorActionPreference = 'Continue'
	try {
		foreach ($argument in @('version', '--version')) {
			$out = (& $exe $argument 2>&1 | Out-String -Width 4096).Trim()
			if ($LASTEXITCODE -eq 0) { return $out }
		}
		return $null
	} finally {
		$ErrorActionPreference = $previous
	}
}

# The junction is what the PATH entry points at, so the PATH is written once and never
# again. Anything else already sitting at that name is not ours to replace.
function Set-Exposure {
	if (Test-Path -LiteralPath $current) {
		$item = Get-Item -LiteralPath $current -Force
		if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
			Fail "$current exists and is not a junction"
		}
		$target = [IO.Path]::GetFullPath([string] $item.Target).TrimEnd('\')
		if ($target -eq [IO.Path]::GetFullPath($prefix).TrimEnd('\')) { return }
		[IO.Directory]::Delete($current)
	}
	New-Item -ItemType Junction -Path $current -Target $prefix | Out-Null

	$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
	$entries = @($machinePath -split ';' | Where-Object { $_ })
	if ($current -notin $entries) {
		[Environment]::SetEnvironmentVariable('Path', (@($entries) + $current) -join ';', 'Machine')
	}
}

# Already here? The pool image is baked straight after this phase and the node is then
# rebuilt from that image, which runs this phase again on a disk that already carries the
# binary. Without this check every node downloads the archive it is already holding.
$existing = Get-Reported (Join-Path $prefix 'k6.exe')
if ($existing -and $existing -match [regex]::Escape($version)) {
	Set-Exposure
	Note "k6 $version is already installed"
	exit 0
}

try {
	New-Item -ItemType Directory -Path $work -Force | Out-Null
	$archive = Join-Path $work $asset
	$sumsPath = Join-Path $work $sums

	Note "downloading $asset"
	Invoke-WebRequest -UseBasicParsing -Uri "$base/$asset" -OutFile $archive
	Invoke-WebRequest -UseBasicParsing -Uri "$base/$sums" -OutFile $sumsPath

	# The file is "<hash>  <filename>", two spaces. Anchored on the whole name so the
	# .msi published beside this .zip cannot be taken for it.
	$line = @(Get-Content -LiteralPath $sumsPath |
		Where-Object { $_ -match '^([0-9a-fA-F]{64})\s+' + [regex]::Escape($asset) + '\s*\z' })[0]
	if (-not $line) { Fail "checksum for $asset was not published" }
	$expected = (($line -split '\s+')[0]).ToLowerInvariant()

	$actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
	if ($actual -ne $expected) { Fail "checksum verification failed for $asset" }

	$unpacked = Join-Path $work 'unpacked'
	Expand-Archive -LiteralPath $archive -DestinationPath $unpacked

	# Searched for rather than named: this archive puts the binary inside a directory
	# named after the build, and that layout is the project's to change.
	$binary = @(Get-ChildItem -LiteralPath $unpacked -Recurse -Filter 'k6.exe' -ErrorAction SilentlyContinue)[0]
	if (-not $binary) { Fail "k6.exe is missing from $asset" }

	New-Item -ItemType Directory -Path $root -Force | Out-Null
	Remove-Item -LiteralPath $prefix -Recurse -Force -ErrorAction SilentlyContinue
	New-Item -ItemType Directory -Path $prefix -Force | Out-Null
	Copy-Item -LiteralPath $binary.FullName -Destination (Join-Path $prefix 'k6.exe') -Force

	Set-Exposure

	# This process started before the PATH was written, so the binary is run by absolute
	# path.
	$reported = Get-Reported (Join-Path $prefix 'k6.exe')
	if (-not $reported) { Fail 'k6 does not run on this node' }
	if ($reported -notmatch [regex]::Escape($version)) {
		Fail "installed version '$reported' does not match $version"
	}
} finally {
	Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Note "k6 $version installed at $prefix"
