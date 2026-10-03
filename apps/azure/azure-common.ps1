# Shared by the three Windows phases, so they cannot disagree with each other
# about where the CLI is or what counts as ours. Dot-sourced, not executed.

$script:ProductName = 'Microsoft Azure CLI'
# This app's own record. The MSI's registry entries say what is installed; this
# one says whether this app is what installed it, which is what uninstall needs
# to know before removing anything.
$script:OwnKey = 'HKLM:\SOFTWARE\orc8r\azure'

function Get-Registry64([string] $path) {
	# A 32-bit PowerShell under WOW64 sees HKLM\SOFTWARE redirected to
	# WOW6432Node, while the x64 MSI writes to the 64-bit view. Asking for the
	# view explicitly makes the answer the same from either.
	$base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
		[Microsoft.Win32.RegistryHive]::LocalMachine,
		[Microsoft.Win32.RegistryView]::Registry64)
	try {
		return $base.OpenSubKey($path)
	} catch {
		return $null
	}
}

function Get-ProgramFiles64 {
	# Set in both bitnesses on 64-bit Windows; $env:ProgramFiles is the 32-bit
	# path inside a 32-bit process.
	if ($env:ProgramW6432) { return $env:ProgramW6432 }
	if ($env:ProgramFiles) { return $env:ProgramFiles }
	throw 'azure: neither ProgramW6432 nor ProgramFiles is set'
}

function Get-AzPath {
	return (Join-Path (Get-ProgramFiles64) 'Microsoft SDKs\Azure\CLI2\wbin\az.cmd')
}

function Get-InstalledVersion {
	# Written by the MSI: HKLM\Software\Microsoft\Microsoft Azure CLI\version,
	# a plain three-part string.
	$key = Get-Registry64 "SOFTWARE\Microsoft\$script:ProductName"
	if (-not $key) { return $null }
	try {
		$value = $key.GetValue('version')
		if ($value) { return [string] $value }
		return $null
	} finally {
		$key.Close()
	}
}

function Get-InstalledProduct {
	# The ProductCode is regenerated on every build (Product Id="*" in the WiX
	# source), so it is looked up rather than hard-coded. The display name is
	# "Microsoft Azure CLI (64-bit)" or "(32-bit)"; the bare name is the
	# deprecated form still found on old nodes. Anchored, because an unanchored
	# wildcard also matches unrelated products whose name merely starts this way.
	$roots = @('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
		'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
	$found = $null
	foreach ($root in $roots) {
		$key = Get-Registry64 $root
		if (-not $key) { continue }
		try {
			foreach ($name in @($key.GetSubKeyNames())) {
				# Only an MSI product has a ProductCode for a key name, and only
				# a GUID can be handed to msiexec /x.
				if ($name -notmatch '^\{[0-9A-Fa-f-]{36}\}\z') { continue }
				$sub = $key.OpenSubKey($name)
				if (-not $sub) { continue }
				try {
					$display = [string] $sub.GetValue('DisplayName')
					if ($display -notmatch '^Microsoft Azure CLI( \((64|32)-bit\))?\z') { continue }
					if ($sub.GetValue('WindowsInstaller') -ne 1) { continue }
					$product = [pscustomobject]@{
						Code    = $name
						Version = [string] $sub.GetValue('DisplayVersion')
						Name    = $display
					}
					# Prefer the 64-bit product when both are somehow present.
					if ($display -like '*64-bit*') { return $product }
					if (-not $found) { $found = $product }
				} finally {
					$sub.Close()
				}
			}
		} finally {
			$key.Close()
		}
	}
	return $found
}

function Get-OwnedVersion {
	$key = Get-Registry64 'SOFTWARE\orc8r\azure'
	if (-not $key) { return $null }
	try {
		$value = $key.GetValue('installedVersion')
		if ($value) { return [string] $value }
		return $null
	} finally {
		$key.Close()
	}
}

function Set-OwnedVersion([string] $version) {
	New-Item -Path $script:OwnKey -Force | Out-Null
	New-ItemProperty -Path $script:OwnKey -Name 'installedVersion' `
		-Value $version -PropertyType String -Force | Out-Null
}

function Clear-OwnedVersion {
	Remove-Item -LiteralPath $script:OwnKey -Recurse -Force -ErrorAction SilentlyContinue
}

function Assert-Administrator([string] $phase) {
	$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
	$principal = [Security.Principal.WindowsPrincipal] $identity
	if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
		throw "azure ${phase}: must run as Administrator; the installer is per-machine"
	}
}

function Invoke-Msi([string[]] $arguments, [string] $phase) {
	$process = Start-Process msiexec.exe -ArgumentList $arguments -Wait -PassThru
	# 3010 is success with a reboot pending, which a headless node does not owe
	# anyone: the CLI works without it.
	if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
		throw "azure ${phase}: msiexec failed with exit code $($process.ExitCode)"
	}
}

function Invoke-Native([scriptblock] $block) {
	# `2>&1` while $ErrorActionPreference is 'Stop' turns anything a native
	# command writes to stderr into a terminating error, which would kill the
	# phase on a node where the CLI merely warns. Lowered for the call alone —
	# the same guard java/install-java.ps1 puts around its own version check.
	$previous = $ErrorActionPreference
	$output = ''
	$code = 1
	try {
		$ErrorActionPreference = 'Continue'
		$output = (& $block 2>&1 | Out-String -Width 4096)
		$code = $LASTEXITCODE
	} finally {
		$ErrorActionPreference = $previous
	}
	return [pscustomobject]@{ Output = $output; ExitCode = $code }
}
