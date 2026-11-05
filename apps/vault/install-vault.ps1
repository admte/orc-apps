<#
.SYNOPSIS
Installs the HashiCorp Vault CLI for the current user.

.DESCRIPTION
Without -Version it installs the latest release, and leaves a vault command that is
already on PATH as it is.

.PARAMETER Version
Vault release to install, e.g. 1.17.2.

.PARAMETER InstallDir
Where vault.exe is installed and added to the user PATH; defaults to
%LOCALAPPDATA%\Programs\Vault.
#>
[CmdletBinding()]
param(
    [string]$Version = '',
    [string]$InstallDir = ''
)

$ErrorActionPreference = "Stop"

if (-not $Version -and (Get-Command vault -ErrorAction SilentlyContinue)) {
    vault version
    exit 0
}

$architecture = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
    "X64" { "amd64" }
    default { throw "vault install: unsupported architecture: $_" }
}

if (-not $Version) {
    $release = Invoke-RestMethod -Uri "https://api.releases.hashicorp.com/v1/releases/vault/latest"
    $Version = $release.version
}
if (-not $Version) {
    throw "vault install: could not determine the latest Vault version"
}
$Version = $Version.TrimStart("v")

$archive = "vault_${Version}_windows_${architecture}.zip"
$baseUrl = "https://releases.hashicorp.com/vault/$Version"
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "vault-$([guid]::NewGuid())"
if (-not $InstallDir) {
    $InstallDir = Join-Path $env:LOCALAPPDATA "Programs\Vault"
}

try {
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    $archivePath = Join-Path $tempDir $archive
    $checksumsPath = Join-Path $tempDir "SHA256SUMS"

    Write-Host "Downloading Vault $Version for windows/$architecture"
    Invoke-WebRequest -Uri "$baseUrl/$archive" -OutFile $archivePath
    Invoke-WebRequest -Uri "$baseUrl/vault_${Version}_SHA256SUMS" -OutFile $checksumsPath

    $checksumLine = Get-Content $checksumsPath |
        Where-Object { $_ -match "^[0-9a-fA-F]{64}\s+\*?$([regex]::Escape($archive))$" } |
        Select-Object -First 1
    if (-not $checksumLine) {
        throw "vault install: checksum for $archive was not published"
    }

    $expected = ($checksumLine -split "\s+")[0].ToLowerInvariant()
    $actual = (Get-FileHash -Algorithm SHA256 $archivePath).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "vault install: checksum verification failed for $archive"
    }

    $unpacked = Join-Path $tempDir "unpacked"
    Expand-Archive -Path $archivePath -DestinationPath $unpacked
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Copy-Item -Path (Join-Path $unpacked "vault.exe") -Destination $InstallDir -Force

    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $pathEntries = @($userPath -split ";" | Where-Object { $_ })
    if ($InstallDir -notin $pathEntries) {
        $newPath = (@($pathEntries) + $InstallDir) -join ";"
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    }

    & (Join-Path $InstallDir "vault.exe") version
} finally {
    if (Test-Path $tempDir) {
        Remove-Item -Path $tempDir -Recurse -Force
    }
}
