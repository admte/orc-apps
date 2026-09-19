$ErrorActionPreference = 'Stop'

# Removal of the app itself. The runner has already stopped, and the stopped hook
# released the registration when the node was terminating; releasing again here is
# best-effort, for the case where the app is taken off a node that keeps running.

function Write-Note($message) {
	Write-Host "gitlab-runner uninstall: $message"
}

if (-not $env:APP_VERSION) {
	throw 'gitlab-runner uninstall: APP_VERSION is required'
}
if ($env:APP_VERSION -notmatch '^\d+\.\d+\.\d+$') {
	throw "gitlab-runner uninstall: invalid APP_VERSION: $env:APP_VERSION"
}

$root = Join-Path $env:ProgramFiles 'gitlab-runner'
$prefix = Join-Path $root $env:APP_VERSION
$current = Join-Path $root 'current'
$runner = Join-Path $prefix 'gitlab-runner.exe'
$config = Join-Path (Join-Path (Get-Location) 'gitlab-runner') 'config.toml'

if ((Test-Path -LiteralPath $runner -PathType Leaf) -and (Test-Path -LiteralPath $config)) {
	& $runner unregister --config $config --all-runners
	if ($LASTEXITCODE -eq 0) {
		Write-Note 'runner unregistered'
	} else {
		Write-Note 'could not unregister; removing the install anyway'
	}
}

# Only an exposure that still points into this version's own tree is ours to
# remove: after an upgrade it belongs to the version that replaced this one.
if (Test-Path -LiteralPath $current) {
	$item = Get-Item -LiteralPath $current -Force
	if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
		$target = [IO.Path]::GetFullPath([string]$item.Target).TrimEnd('\')
		if ($target -eq [IO.Path]::GetFullPath($prefix).TrimEnd('\')) {
			[IO.Directory]::Delete($current)
		}
	}
}

Remove-Item -LiteralPath $prefix -Recurse -Force -ErrorAction SilentlyContinue

if ((Test-Path -LiteralPath $root) -and -not (Test-Path -LiteralPath $current)) {
	$remaining = @(Get-ChildItem -LiteralPath $root -Force)
	if ($remaining.Count -eq 0) {
		$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
		$entries = @($machinePath -split ';' | Where-Object {
			$_ -and $_.TrimEnd('\') -ne $current.TrimEnd('\')
		})
		[Environment]::SetEnvironmentVariable('Path', $entries -join ';', 'Machine')
		Remove-Item -LiteralPath $root -Force
	}
}

Write-Note "removed version=$($env:APP_VERSION) dir=$prefix"
