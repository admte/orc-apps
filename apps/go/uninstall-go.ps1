<#
.SYNOPSIS
Removes one Go release that install-go.ps1 installed.

.PARAMETER Version
Go release, e.g. 1.22.5 (default: the current release).
#>
[CmdletBinding()]
param(
	[string]$Version = ''
)

$ErrorActionPreference = 'Stop'

if (-not $Version) {
	# The install ran without a version and took the then-newest release, so the
	# release the current junction points at is the one to remove.
	$current = Join-Path (Join-Path $env:ProgramFiles 'go') 'current'
	$item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
	if (-not $item -or -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
		Write-Host 'go uninstall: no installed release to remove'
		exit 0
	}
	$Version = Split-Path -Leaf ([string]$item.Target).TrimEnd('\')
}

$requested = $Version
$version = $requested -replace '^go', ''
if ($version -notmatch '^\d+\.\d+(\.\d+)?$') {
	throw "go uninstall: invalid version: $requested"
}
$root = Join-Path $env:ProgramFiles 'go'
$prefix = Join-Path $root $version
$current = Join-Path $root 'current'
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
