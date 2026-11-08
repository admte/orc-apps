<#
.SYNOPSIS
Removes one JDK release that install-java.ps1 installed.

.PARAMETER Version
JDK release, e.g. 21.0.4. Defaults to the release the current junction points
at.
#>
[CmdletBinding()]
param(
	[string]$Version = ''
)

$ErrorActionPreference = 'Stop'

if (-not $env:ProgramFiles) {
	throw 'java uninstall: ProgramFiles is required'
}

if (-not $Version) {
	# The install took the newest release because the request resolved to the
	# implicit `default` tag, so remove the one the junction points at.
	$link = Join-Path (Join-Path $env:ProgramFiles 'java') 'current'
	if (-not (Test-Path -LiteralPath $link)) {
		Write-Host 'java uninstall: no installed version to remove'
		exit 0
	}
	$linkItem = Get-Item -LiteralPath $link -Force
	if (-not ($linkItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
		Write-Host "java uninstall: $link is not a junction; leaving it in place"
		exit 0
	}
	$Version = Split-Path -Leaf ([string] $linkItem.Target)
}

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
	throw "java uninstall: invalid version: $Version"
}

$root = Join-Path $env:ProgramFiles 'java'
$prefix = Join-Path $root $Version
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

if (-not (Test-Path -LiteralPath $current)) {
	$javaHome = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'Machine')
	if ($javaHome -and $javaHome.TrimEnd('\') -eq $current.TrimEnd('\')) {
		[Environment]::SetEnvironmentVariable('JAVA_HOME', $null, 'Machine')
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
