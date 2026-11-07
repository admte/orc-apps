<#
.SYNOPSIS
Removes the uv that install-uv.ps1 installed, and its machine PATH entry.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

if (-not $env:ProgramFiles) {
	throw 'uv uninstall: ProgramFiles is required'
}

$installDir = Join-Path $env:ProgramFiles 'uv'

foreach ($program in @('uv.exe', 'uvx.exe', 'uvw.exe')) {
	$path = Join-Path $installDir $program
	if (Test-Path -LiteralPath $path) {
		Remove-Item -LiteralPath $path -Force
	}
}

if (Test-Path -LiteralPath $installDir) {
	$remaining = @(Get-ChildItem -LiteralPath $installDir -Force)
	if ($remaining.Count -gt 0) {
		Write-Warning "uv uninstall: keeping $installDir, which holds files uv did not install"
		exit 0
	}
	Remove-Item -LiteralPath $installDir -Force
}

$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$entries = @($machinePath -split ';' | Where-Object { $_ })
$kept = @($entries | Where-Object { $_.TrimEnd('\') -ne $installDir.TrimEnd('\') })
if ($kept.Count -ne $entries.Count) {
	[Environment]::SetEnvironmentVariable('Path', $kept -join ';', 'Machine')
}
