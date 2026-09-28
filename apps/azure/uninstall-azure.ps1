$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'azure-common.ps1')

# Removes the Azure CLI, but only when it is this app's to remove.
#
# Two checks, and both matter. The MSI does a major upgrade in place: installing
# 2.90 over 2.89 removes 2.89 itself, before it installs. The runtime still runs
# the superseded version's uninstall afterwards, so an uninstall that removed
# whatever it found would take away the version that had just replaced it and
# leave the node with no CLI at all. And on a node that already had the Azure
# CLI, installed by somebody else, nothing here is ours — install records what
# it installed, and without that record this phase removes nothing.
#
# The CLI's sign-in state is deliberately left alone. It lives in the profile of
# whoever the start phase ran as, it may hold more than this app put there, and
# it is not ours to delete.

Assert-Administrator 'uninstall'

$installed = Get-InstalledVersion
if (-not $installed) {
	Clear-OwnedVersion
	Write-Host 'azure uninstall: the Azure CLI is not installed on this node'
	exit 0
}

$owned = Get-OwnedVersion
if (-not $owned) {
	Write-Host "azure uninstall: $installed was not installed by this app; leaving it in place"
	exit 0
}

# APP_VERSION is unset when the request resolved to the implicit `default` tag.
# What this app recorded stands in for it, because a newer release may have been
# published since and that one was never installed here.
$version = $env:APP_VERSION
if ($version) {
	if ($version -notmatch '^\d+\.\d+\.\d+\z') {
		throw "azure uninstall: invalid APP_VERSION: $version"
	}
} else {
	$version = $owned
	Write-Host "azure uninstall: no version was requested; removing $version, the version this app installed"
}

if ($version -ne $installed) {
	# The usual cause is an upgrade: the new version's install already removed
	# this one, and the runtime is only now getting round to its uninstall.
	Write-Host "azure uninstall: $installed is installed, not $version; leaving it in place"
	exit 0
}

$product = Get-InstalledProduct
if (-not $product) {
	Clear-OwnedVersion
	Write-Host 'azure uninstall: no installer entry found for the Azure CLI; nothing to remove'
	exit 0
}

Write-Host "azure uninstall: removing $($product.Name) $($product.Version)"
Invoke-Msi @('/x', $product.Code, '/qn', '/norestart') 'uninstall'

$remaining = Get-InstalledVersion
if ($remaining) {
	throw "azure uninstall: the Azure CLI is still registered as $remaining after msiexec reported success"
}

Clear-OwnedVersion
# The MSI added its directory to the machine PATH with Permanent="no", so it
# takes the entry away again on removal. Nothing to clean up here.
Write-Host "azure uninstall: removed $($product.Name)"
