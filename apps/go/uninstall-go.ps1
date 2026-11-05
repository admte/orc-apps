$ErrorActionPreference = 'Stop'

if (-not $env:ProgramFiles) {
	throw 'go uninstall: ProgramFiles is required'
}

$root = Join-Path $env:ProgramFiles 'go'
$current = Join-Path $root 'current'

$version = $env:APP_VERSION -replace '^go', ''
if (-not $version) {
	# The install ran without a resolved version and took the then-newest
	# release, so the tree the junction points at is the one to remove.
	if (-not (Test-Path -LiteralPath $current)) {
		Write-Host 'go uninstall: no installed version to remove'
		exit 0
	}
	$item = Get-Item -LiteralPath $current -Force
	if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
		Write-Host "go uninstall: $current is not a junction; leaving it in place"
		exit 0
	}
	$version = Split-Path -Leaf ([string] $item.Target)
	Write-Host "go uninstall: no version was requested; removing $version, the version the junction points at"
}
if ($version -notmatch '^\d+\.\d+(\.\d+)?$') {
	throw "go uninstall: invalid version: $version"
}

$prefix = Join-Path $root $version
$pathEntry = Join-Path $current 'bin'

if (Test-Path -LiteralPath $current) {
	$item = Get-Item -LiteralPath $current -Force
	if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
		$target = [IO.Path]::GetFullPath([string]$item.Target).TrimEnd('\')
		$owned = [IO.Path]::GetFullPath($prefix).TrimEnd('\')
		if ($target -eq $owned) {
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
			$_ -and $_.TrimEnd('\') -ne $pathEntry.TrimEnd('\')
		})
		[Environment]::SetEnvironmentVariable('Path', $entries -join ';', 'Machine')
		Remove-Item -LiteralPath $root -Force
	}
}
