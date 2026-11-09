<#
.SYNOPSIS
Removes one Node.js release that install-node.ps1 installed.

.PARAMETER Version
Node.js release, e.g. 20.17.0 (default: the current release).
#>
[CmdletBinding()]
param(
	[string]$Version = ''
)

$ErrorActionPreference = 'Stop'

if (-not $Version) {
	# The install ran without a version and took the then-newest release, so the
	# release the current junction points at is the one to remove.
	$current = Join-Path (Join-Path $env:ProgramFiles 'node') 'current'
	$item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
	if (-not $item -or -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
		Write-Host 'node uninstall: no installed release to remove'
		exit 0
	}
	$Version = Split-Path -Leaf ([string]$item.Target).TrimEnd('\')
}

$requested = $Version
$version = $requested.TrimStart('v')
if ($version -notmatch '^\d+\.\d+\.\d+$') {
	throw "node uninstall: invalid version: $requested"
}
$root = Join-Path $env:ProgramFiles 'node'
$prefix = Join-Path $root $version
$current = Join-Path $root 'current'

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
			$_ -and $_.TrimEnd('\') -ne $current.TrimEnd('\')
		})
		[Environment]::SetEnvironmentVariable('Path', $entries -join ';', 'Machine')
		Remove-Item -LiteralPath $root -Force
	}
}
