$ErrorActionPreference = 'Stop'

# Installs one mise release under Program Files and exposes it through a `current`
# junction plus a single machine PATH entry — the shape go, java, node, trivy, syft,
# cosign, snyk and checkov use on Windows, so switching versions never rewrites the PATH.
#
# Like cosign and snyk, the project publishes a bare .exe alongside its archives, so the
# plain executable is taken and there is nothing to unpack.

function Fail($message) { throw "mise install: $message" }
function Note($message) { Write-Host "mise install: $message" }

if (-not $env:ProgramFiles) { Fail 'ProgramFiles is required' }

# PROCESSOR_ARCHITEW6432 is set only inside a 32-bit process on a 64-bit system, where
# PROCESSOR_ARCHITECTURE would read x86 and pick the wrong asset.
$machineArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
switch ($machineArch) {
	'AMD64' { $platform = 'windows-x64' }
	# The runtime DLLs packaged beside this script are x64, and arm64 is not declared
	# under `platforms`. Adding it means packaging the arm64 pair as well.
	'ARM64' { Fail 'windows/arm64 is not supported by this package' }
	default { Fail "unsupported architecture $machineArch" }
}

# Windows PowerShell 5.1 leaves TLS at the machine default, which on older images can
# still be 1.0; GitHub requires 1.2.
[Net.ServicePointManager]::SecurityProtocol =
	[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Windows PowerShell 5.1 redraws Invoke-WebRequest's progress bar on every block it reads.
# On a node there is no console to draw to and the redraw costs more than the transfer:
# checkov's 53 MB archive took nine minutes with the bar on and four with it off, against
# eighteen seconds for the same download on Linux.
$ProgressPreference = 'SilentlyContinue'

$version = $env:APP_VERSION -replace '^v', ''
if (-not $version) {
	# APP_VERSION arrives unset when the request resolved to the implicit `default` tag.
	Note 'no version was requested; taking the newest release'
	try {
		$latest = Invoke-RestMethod -UseBasicParsing -Headers @{ 'User-Agent' = 'orc-mise' } `
			-Uri 'https://api.github.com/repos/jdx/mise/releases/latest'
	} catch {
		Fail "could not read the newest release from GitHub: $($_.Exception.Message)"
	}
	$version = ([string] $latest.tag_name) -replace '^v', ''
	Note "newest release is $version"
}
if ($version -notmatch '^\d+\.\d+\.\d+\z') { Fail "invalid version: $version" }

# The version is part of the asset name, as with k6.
$asset = "mise-v$version-$platform.exe"
$sums = 'SHASUMS256.txt'
$base = "https://github.com/jdx/mise/releases/download/v$version"

$root = Join-Path $env:ProgramFiles 'mise'
$prefix = Join-Path $root $version
$current = Join-Path $root 'current'
$work = Join-Path ([IO.Path]::GetTempPath()) "mise-$([guid]::NewGuid())"

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

# mise is Rust built against the MSVC toolchain, so mise.exe needs the Visual C++ runtime.
# Those DLLs ship with the Redistributable, not with Windows, and a Server Core node has
# neither — the binary exits 0xC0000135 (STATUS_DLL_NOT_FOUND) before reaching main,
# printing nothing at all.
#
# They are therefore packaged beside this script and copied next to mise.exe. Windows
# searches the executable's own directory first, so this needs no administrator rights and
# changes nothing outside this app's own tree — unlike installing the Redistributable,
# which is a system component and would outlive this app's uninstall.
$runtimeDlls = @('vcruntime140.dll', 'vcruntime140_1.dll')

function Copy-Runtime($destination) {
	# $PSScriptRoot is the directory the runtime unpacked this app's payload into, so the
	# DLLs sit beside this script. The current directory is tried as well, which is what
	# the manual test below uses.
	$searched = @($PSScriptRoot, (Get-Location).Path) | Where-Object { $_ }
	foreach ($dll in $runtimeDlls) {
		$source = $searched |
			ForEach-Object { Join-Path $_ $dll } |
			Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
			Select-Object -First 1
		if (-not $source) { Fail "$dll was not packaged; looked in $($searched -join ', ')" }
		Copy-Item -LiteralPath $source -Destination (Join-Path $destination $dll) -Force
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
$existing = Get-Reported (Join-Path $prefix 'mise.exe')
if ($existing -and $existing -match [regex]::Escape($version)) {
	Set-Exposure
	Note "mise $version is already installed"
	exit 0
}

try {
	New-Item -ItemType Directory -Path $work -Force | Out-Null
	$downloaded = Join-Path $work $asset
	$sumsPath = Join-Path $work $sums

	Note "downloading $asset"
	Invoke-WebRequest -UseBasicParsing -Uri "$base/$asset" -OutFile $downloaded
	Invoke-WebRequest -UseBasicParsing -Uri "$base/$sums" -OutFile $sumsPath

	# Anchored on the whole name: the .exe shares its stem with the .zip of the same
	# build. The names in this file carry a "./" prefix, which the optional group allows
	# for without loosening the match.
	$line = @(Get-Content -LiteralPath $sumsPath |
		Where-Object { $_ -match '^([0-9a-fA-F]{64})\s+(\./)?' + [regex]::Escape($asset) + '\s*\z' })[0]
	if (-not $line) { Fail "checksum for $asset was not published" }
	$expected = (($line -split '\s+')[0]).ToLowerInvariant()

	$actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $downloaded).Hash.ToLowerInvariant()
	if ($actual -ne $expected) { Fail "checksum verification failed for $asset" }

	New-Item -ItemType Directory -Path $root -Force | Out-Null
	Remove-Item -LiteralPath $prefix -Recurse -Force -ErrorAction SilentlyContinue
	New-Item -ItemType Directory -Path $prefix -Force | Out-Null
	Copy-Item -LiteralPath $downloaded -Destination (Join-Path $prefix 'mise.exe') -Force
	Copy-Runtime $prefix

	Set-Exposure

	# This process started before the PATH was written, so the binary is run by absolute
	# path.
	$reported = Get-Reported (Join-Path $prefix 'mise.exe')
	if (-not $reported) { Fail 'mise does not run on this node' }
	if ($reported -notmatch [regex]::Escape($version)) {
		Fail "installed version '$reported' does not match $version"
	}
} finally {
	Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Note "mise $version installed at $prefix"
