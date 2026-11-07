<#
.SYNOPSIS
Removes one Node.js release that install-node.ps1 installed.

.PARAMETER Version
Node.js release, e.g. 20.17.0. Defaults to the release the current junction
points at.
#>
[CmdletBinding()]
param(
	[string]$Version = ''
)

$ErrorActionPreference = 'Stop'

if (-not $env:ProgramFiles) {
	throw 'node uninstall: ProgramFiles is required'
}

if (-not $Version) {
	# The install took the newest release because the request resolved to the
	# implicit `default` tag, so remove the one the junction points at.
	$link = Join-Path (Join-Path $env:ProgramFiles 'node') 'current'
	if (-not (Test-Path -LiteralPath $link)) {
		Write-Host 'node uninstall: no installed version to remove'
		exit 0
	}
	$linkItem = Get-Item -LiteralPath $link -Force
	if (-not ($linkItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
		Write-Host "node uninstall: $link is not a junction; leaving it in place"
		exit 0
	}
	$Version = Split-Path -Leaf ([string] $linkItem.Target)
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
