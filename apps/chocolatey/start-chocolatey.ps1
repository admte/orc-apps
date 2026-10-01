$ErrorActionPreference = 'Stop'

# Installs the packages the operator named. Without any, the node is simply left with
# Chocolatey ready — the same thing `apt` does when its parameter is empty.

function Fail($message) { throw "chocolatey packages: $message" }
function Note($message) { Write-Host "chocolatey packages: $message" }

$root = [Environment]::GetEnvironmentVariable('ChocolateyInstall', 'Machine')
if (-not $root) { $root = $env:ChocolateyInstall }
if (-not $root) { $root = Join-Path $env:ProgramData 'chocolatey' }

$choco = Join-Path $root 'bin\choco.exe'
if (-not (Test-Path -LiteralPath $choco -PathType Leaf)) {
	Fail "chocolatey is not installed; expected choco.exe at $choco"
}

# -split on whitespace, then the empty entries dropped: a parameter typed with newlines
# or double spaces should behave the same as one typed with single spaces.
$packages = @(($env:PACKAGES -split '\s+') | Where-Object { $_ })
if ($packages.Count -eq 0) {
	Note 'chocolatey is ready; no packages were requested'
	exit 0
}

# A package id is the only thing this parameter may hold. Without the check, a value
# carrying a space and a dash would turn into extra options on the command line below —
# `--force`, or a different `--source` than the one configured.
foreach ($package in $packages) {
	if ($package -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*\z') {
		Fail "'$package' is not a valid package name"
	}
}

$arguments = @('install') + $packages + @('-y', '--no-progress')

$source = $env:CHOCOLATEY_SOURCE
if ($source) {
	# Same reasoning as above, and the scheme is pinned so the feed cannot be a local
	# path or a UNC share that happened to end up in the parameter.
	if ($source -notmatch '^https?://[^\s]+\z') {
		Fail 'chocolatey_source must be an http or https URL'
	}
	$arguments += @('--source', $source)
	Note "using the feed at $source"
} else {
	# The Chocolatey terms of use reserve the Community Repository for individuals from
	# 1 January 2027; organisations are expected to point at their own feed, which may
	# cache the community one upstream. Said once here so that a pool still using the
	# default is visible in the node log rather than discovered in January.
	Note 'using the public Chocolatey Community Repository; set chocolatey_source to an internal feed before 2027'
}

Note ("installing " + ($packages -join ', '))

# The preference is lowered for the call itself: with it at Stop, anything Chocolatey
# writes to standard error would end this script before its exit code could be read, and
# the exit code is what actually says whether the install worked.
$previous = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
	& $choco @arguments
	$code = $LASTEXITCODE
} finally {
	$ErrorActionPreference = $previous
}

switch ($code) {
	0 { Note 'packages installed' }
	1641 { Note 'packages installed; a package asked for a restart, which this node has not been given' }
	3010 { Note 'packages installed; a package asked for a restart, which this node has not been given' }
	default { Fail "chocolatey exited with code $code; see $root\logs\chocolatey.log on the node" }
}
