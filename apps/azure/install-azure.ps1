$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'azure-common.ps1')

# Installs one Azure CLI version from Microsoft's published MSI.
#
# Windows takes a different route from Linux by necessity: there is no wheel
# install here, because Microsoft ships the CLI for Windows as an installer that
# brings its own Python. The MSI is per-machine, it puts `az.cmd` under Program
# Files and adds that directory to the machine PATH itself — so unlike every
# other Windows app in this catalog there is no junction to manage and no PATH
# entry to write.
#
# Only one version can be installed at a time, and the MSI removes the previous
# one before installing itself.

$Feed = 'https://azcliprod.blob.core.windows.net/msi'

if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64' -and $env:PROCESSOR_ARCHITEW6432 -ne 'AMD64') {
	throw "azure install: unsupported architecture $env:PROCESSOR_ARCHITECTURE"
}
Assert-Administrator 'install'

# Windows PowerShell 5.1 leaves TLS at whatever the machine default is, which on
# Server 2016 and 2019 can still be 1.0 — and both hosts below require 1.2.
[Net.ServicePointManager]::SecurityProtocol =
	[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# APP_VERSION is unset when the request resolved to the implicit `default` tag.
# The newest is then read from PyPI, which carries the same version numbers the
# MSI is named after. The two are published by different pipelines, though, so
# a release can exist on PyPI hours before its MSI does — the download below
# says so plainly rather than showing a bare 404.
$version = $env:APP_VERSION
$resolved = $false
if ($version) {
	if ($version -notmatch '^\d+\.\d+\.\d+\z') {
		throw "azure install: invalid APP_VERSION: $version"
	}
} else {
	Write-Host 'azure install: no version was requested; taking the newest published'
	$index = Invoke-RestMethod -UseBasicParsing -Uri 'https://pypi.org/pypi/azure-cli/json'
	$version = [string] $index.info.version
	if ($version -notmatch '^\d+\.\d+\.\d+\z') {
		throw "azure install: the release index named no usable version: '$version'"
	}
	$resolved = $true
	Write-Host "azure install: newest published azure-cli is $version"
}

$installed = Get-InstalledVersion
if ($installed -eq $version) {
	# Already there. Recorded as ours all the same: this app was asked for it,
	# and without the record uninstall would refuse to take it away.
	Set-OwnedVersion $version
	Write-Host "azure install: azure-cli $version is already installed"
	exit 0
}

# The MSI refuses to install over a newer product, so a deliberate downgrade has
# to remove what is there first. An upgrade needs no such thing: the MSI removes
# the older product itself, before it installs.
if ($installed) {
	$isDowngrade = $false
	try {
		$isDowngrade = [version] $installed -gt [version] $version
	} catch {
		throw "azure install: the installed version is not a version number: '$installed'"
	}
	if ($isDowngrade) {
		$product = Get-InstalledProduct
		if ($product) {
			Write-Host "azure install: removing $($product.Name) $($product.Version) to install the older $version"
			Invoke-Msi @('/x', $product.Code, '/qn', '/norestart') 'install'
		}
	}
}

# -x64 is the exact suffix Microsoft publishes the 64-bit installer under; the
# unsuffixed name is the 32-bit build.
$asset = "azure-cli-$version-x64.msi"
$work = Join-Path ([System.IO.Path]::GetTempPath()) "azure-cli-$([guid]::NewGuid())"

try {
	New-Item -ItemType Directory -Path $work -Force | Out-Null
	$msi = Join-Path $work $asset

	Write-Host "azure install: downloading $asset"
	try {
		Invoke-WebRequest -UseBasicParsing -Uri "$Feed/$asset" -OutFile $msi
	} catch {
		if ($resolved) {
			throw "azure install: $asset is not published yet. The version list and the Windows installer come from different pipelines, so a release can appear on one before the other. Choose a specific version instead of the default."
		}
		throw "azure install: could not download $asset : $($_.Exception.Message)"
	}

	# Microsoft publishes no checksum or signature file beside the MSI, unlike
	# Amazon, so there is nothing to compare a hash against. What the file does
	# carry is its own Authenticode signature, so that is checked instead — and
	# the publisher is asserted, not merely logged: "validly signed" on its own
	# only means somebody this machine trusts signed it.
	$signature = Get-AuthenticodeSignature -LiteralPath $msi
	if ($signature.Status -eq 'UnknownError') {
		# Revocation checking could not complete — a closed network, not a bad
		# file. The publisher check below still has to pass.
		Write-Host "azure install: warning: the signature could not be fully checked ($($signature.StatusMessage))"
	} elseif ($signature.Status -ne 'Valid') {
		throw "azure install: $asset is not validly signed (status $($signature.Status)); refusing to install it"
	}
	$subject = [string] $signature.SignerCertificate.Subject
	if ($subject -notmatch 'O=Microsoft Corporation') {
		throw "azure install: $asset is not signed by Microsoft (signer: $subject); refusing to install it"
	}
	Write-Host "azure install: signed by $subject"

	Invoke-Msi @('/i', "`"$msi`"", '/qn', '/norestart') 'install'
} finally {
	Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

# The MSI prepends its own directory to the machine PATH, but this process was
# started before that happened, so the absolute path is used.
$az = Get-AzPath
if (-not (Test-Path -LiteralPath $az -PathType Leaf)) {
	throw "azure install: the Azure CLI was not found at $az after installing"
}

$installed = Get-InstalledVersion
if ($installed -ne $version) {
	throw "azure install: installed version '$installed' does not match $version"
}

# Telemetry is off for this one command; it stays on for the node's own use.
$env:AZURE_CORE_COLLECT_TELEMETRY = 'false'
$probe = Invoke-Native { & $az version }
if ($probe.ExitCode -ne 0) {
	throw "azure install: azure-cli $installed does not run on this node: $($probe.Output)"
}

Set-OwnedVersion $installed
Write-Host "azure install: azure-cli $installed installed at $(Split-Path -Parent $az)"
