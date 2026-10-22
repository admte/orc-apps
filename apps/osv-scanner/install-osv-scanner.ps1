$ErrorActionPreference = 'Stop'

# Installs one OSV-Scanner release under Program Files and exposes it through a `current`
# junction plus a single machine PATH entry — the shape go, java, node, trivy, syft,
# cosign, snyk, checkov and mise use on Windows, so switching versions never rewrites the
# PATH.
#
# Like cosign and snyk, the project publishes bare .exe files, so there is nothing to
# unpack. The checksums come as one file for the whole release rather than one per asset.

function Fail($message) { throw "osv-scanner install: $message" }
function Note($message) { Write-Host "osv-scanner install: $message" }

if (-not $env:ProgramFiles) { Fail 'ProgramFiles is required' }

# PROCESSOR_ARCHITEW6432 is set only inside a 32-bit process on a 64-bit system, where
# PROCESSOR_ARCHITECTURE would read x86 and pick the wrong asset.
$machineArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
switch ($machineArch) {
	'AMD64' { $asset = 'osv-scanner_windows_amd64.exe' }
	'ARM64' { $asset = 'osv-scanner_windows_arm64.exe' }
	default { Fail "unsupported architecture $machineArch" }
}

# Windows PowerShell 5.1 leaves TLS at the machine default, which on older images can
# still be 1.0; GitHub requires 1.2.
[Net.ServicePointManager]::SecurityProtocol =
	[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Windows PowerShell 5.1 redraws Invoke-WebRequest's progress bar on every block it reads.
# On a node there is no console to draw to and the redraw costs more than the transfer:
# mise's download went from over nine minutes to under four seconds with the bar off.
$ProgressPreference = 'SilentlyContinue'

$version = $env:APP_VERSION -replace '^v', ''
if (-not $version) {
	# APP_VERSION arrives unset when the request resolved to the implicit `default` tag.
	Note 'no version was requested; taking the newest release'
	try {
		$latest = Invoke-RestMethod -UseBasicParsing -Headers @{ 'User-Agent' = 'orc-osv-scanner' } `
			-Uri 'https://api.github.com/repos/google/osv-scanner/releases/latest'
	} catch {
		Fail "could not read the newest release from GitHub: $($_.Exception.Message)"
	}
	$version = ([string] $latest.tag_name) -replace '^v', ''
	Note "newest release is $version"
}
if ($version -notmatch '^\d+\.\d+\.\d+\z') { Fail "invalid version: $version" }

# One checksums file for every asset in the release.
$sums = 'osv-scanner_SHA256SUMS'
$base = "https://github.com/google/osv-scanner/releases/download/v$version"

$root = Join-Path $env:ProgramFiles 'osv-scanner'
$prefix = Join-Path $root $version
$current = Join-Path $root 'current'
$work = Join-Path ([IO.Path]::GetTempPath()) "osv-scanner-$([guid]::NewGuid())"

# Runs the binary and returns what it reports, or $null. Both spellings are tried. The
# preference is lowered because `2>&1` on a native command is a terminating error while
# it is Stop.
function Get-Reported($exe) {
	if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { return $null }
	$previous = $ErrorActionPreference
	$ErrorActionPreference = 'Continue'
	try {
		foreach ($argument in @('--version', 'version')) {
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
# binary.
$existing = Get-Reported (Join-Path $prefix 'osv-scanner.exe')
if ($existing -and $existing -match [regex]::Escape($version)) {
	Set-Exposure
	Note "osv-scanner $version is already installed"
	exit 0
}

try {
	New-Item -ItemType Directory -Path $work -Force | Out-Null
	$downloaded = Join-Path $work $asset
	$sumsPath = Join-Path $work $sums

	Note "downloading $asset"
	Invoke-WebRequest -UseBasicParsing -Uri "$base/$asset" -OutFile $downloaded
	Invoke-WebRequest -UseBasicParsing -Uri "$base/$sums" -OutFile $sumsPath

	# Anchored on the whole name rather than a prefix, the way the Linux script matches
	# the awk field.
	$line = @(Get-Content -LiteralPath $sumsPath |
		Where-Object { $_ -match '^([0-9a-fA-F]{64})\s+(\./)?' + [regex]::Escape($asset) + '\s*\z' })[0]
	if (-not $line) { Fail "checksum for $asset was not published" }
	$expected = (($line -split '\s+')[0]).ToLowerInvariant()

	$actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $downloaded).Hash.ToLowerInvariant()
	if ($actual -ne $expected) { Fail "checksum verification failed for $asset" }

	New-Item -ItemType Directory -Path $root -Force | Out-Null
	Remove-Item -LiteralPath $prefix -Recurse -Force -ErrorAction SilentlyContinue
	New-Item -ItemType Directory -Path $prefix -Force | Out-Null
	Copy-Item -LiteralPath $downloaded -Destination (Join-Path $prefix 'osv-scanner.exe') -Force

	Set-Exposure

	# This process started before the PATH was written, so the binary is run by absolute
	# path.
	$reported = Get-Reported (Join-Path $prefix 'osv-scanner.exe')
	if (-not $reported) { Fail 'osv-scanner does not run on this node' }
	if ($reported -notmatch [regex]::Escape($version)) {
		Fail "installed version '$reported' does not match $version"
	}
} finally {
	Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Note "osv-scanner $version installed at $prefix"
