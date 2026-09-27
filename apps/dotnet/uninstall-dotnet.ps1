$ErrorActionPreference = 'Stop'

# Removes one SDK band from the shared root, and nothing that was not ours. See
# uninstall-dotnet.sh for the reasoning: only sdk\<version> is ours, the shared
# runtimes beside it may still be needed by another installed band, and both the
# root and the PATH entry go only if the install phase is the one that added
# them — on Windows the default root is Microsoft's own default location.

if ($env:DOTNET_INSTALL_ROOT) {
	$root = $env:DOTNET_INSTALL_ROOT
} else {
	if (-not $env:ProgramFiles) {
		throw 'dotnet uninstall: ProgramFiles is required'
	}
	$root = Join-Path $env:ProgramFiles 'dotnet'
}
$marker = Join-Path $root '.orc-dotnet-install'

function Get-MarkerLines {
	if (Test-Path -LiteralPath $marker -PathType Leaf) {
		return @(Get-Content -LiteralPath $marker)
	}
	return @()
}

function Get-MarkerFlag([string] $name) {
	return [bool](@(Get-MarkerLines) -match "^$name=1$")
}

$rootCreated = Get-MarkerFlag 'root-created'
$pathAdded = Get-MarkerFlag 'path-added'

# APP_VERSION is unset when the assignment resolved to the implicit `default`
# tag, exactly as it was at install. What install put here is recorded in the
# marker, so the answer is read rather than recomputed — a newer patch may have
# been published since, and that one was never installed.
$version = $env:APP_VERSION
if (-not $version) {
	$recorded = @(Get-MarkerLines | Where-Object { $_ -like 'sdk=*' })
	if ($recorded.Count -eq 0) {
		throw "dotnet uninstall: no version was requested and $marker records none; nothing to remove"
	}
	$version = ($recorded[-1] -split '=', 2)[1]
	Write-Host "dotnet uninstall: no version was requested; removing $version, the last this app installed"
}
if ($version -notmatch '^\d+\.\d+\.\d+$') {
	throw "dotnet uninstall: invalid APP_VERSION: $version"
}

$band = Join-Path $root "sdk\$version"
if (Test-Path -LiteralPath $band -PathType Container) {
	Remove-Item -LiteralPath $band -Recurse -Force
	Write-Host "dotnet uninstall: removed sdk\$version"
} else {
	Write-Host "dotnet uninstall: no sdk\$version to remove under $root"
}

# The record goes with the thing it recorded, so a later uninstall without a
# version does not point at something already gone.
$kept = @(Get-MarkerLines | Where-Object { $_ -ne "sdk=$version" })
if ($kept.Count -gt 0 -and (Test-Path -LiteralPath $marker -PathType Leaf)) {
	$kept | Set-Content -LiteralPath $marker -Encoding ASCII
}

# Only version directories count. sdk\ also holds NuGetFallbackFolder on the
# older bands, and a failed install can leave something else there; counting
# those would keep a root that has no SDK left in it.
$sdkRoot = Join-Path $root 'sdk'
$remaining = @()
if (Test-Path -LiteralPath $sdkRoot -PathType Container) {
	$remaining = @(
		Get-ChildItem -LiteralPath $sdkRoot -Force -Directory |
			Where-Object { $_.Name -match '^\d+\.\d+\.\d+' }
	)
}

if ($remaining.Count -gt 0) {
	Write-Host "dotnet uninstall: kept $root - $($remaining.Count) other SDK version(s) still installed"
	return
}

# Only if this app put it there. A node whose .NET predates the app keeps its
# own PATH entry, which is the whole point of recording the fact at install.
if ($pathAdded) {
	$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
	$entries = @($machinePath -split ';' | Where-Object { $_ })
	$kept = @($entries | Where-Object { $_.TrimEnd('\') -ne $root.TrimEnd('\') })
	if ($kept.Count -ne $entries.Count) {
		[Environment]::SetEnvironmentVariable('Path', $kept -join ';', 'Machine')
		Write-Host "dotnet uninstall: removed $root from the machine PATH"
	}
}

if ($rootCreated) {
	Remove-Item -LiteralPath $root -Recurse -Force
	Write-Host "dotnet uninstall: removed $root with the last SDK version"
} else {
	# The root stays, so the record of what we touched goes instead of lingering
	# inside someone else's installation.
	Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
	Write-Host "dotnet uninstall: kept $root - this node had .NET before the app was installed"
}
