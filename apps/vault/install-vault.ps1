$ErrorActionPreference = "Stop"

if (-not $env:VAULT_VERSION -and (Get-Command vault -ErrorAction SilentlyContinue)) {
    vault version
    exit 0
}

$architecture = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
    "X64" { "amd64" }
    default { throw "vault install: unsupported architecture: $_" }
}

$version = $env:VAULT_VERSION
if (-not $version) {
    $release = Invoke-RestMethod -Uri "https://api.releases.hashicorp.com/v1/releases/vault/latest"
    $version = $release.version
}
if (-not $version) {
    throw "vault install: could not determine the latest Vault version"
}
$version = $version.TrimStart("v")

$archive = "vault_${version}_windows_${architecture}.zip"
$baseUrl = "https://releases.hashicorp.com/vault/$version"
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "vault-$([guid]::NewGuid())"
$installDir = if ($env:VAULT_INSTALL_DIR) {
    $env:VAULT_INSTALL_DIR
} else {
    Join-Path $env:LOCALAPPDATA "Programs\Vault"
}

try {
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    $archivePath = Join-Path $tempDir $archive
    $checksumsPath = Join-Path $tempDir "SHA256SUMS"

    Write-Host "Downloading Vault $version for windows/$architecture"
    Invoke-WebRequest -Uri "$baseUrl/$archive" -OutFile $archivePath
    Invoke-WebRequest -Uri "$baseUrl/vault_${version}_SHA256SUMS" -OutFile $checksumsPath

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
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    Copy-Item -Path (Join-Path $unpacked "vault.exe") -Destination $installDir -Force

    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $pathEntries = @($userPath -split ";" | Where-Object { $_ })
    if ($installDir -notin $pathEntries) {
        $newPath = (@($pathEntries) + $installDir) -join ";"
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    }

    & (Join-Path $installDir "vault.exe") version
} finally {
    if (Test-Path $tempDir) {
        Remove-Item -Path $tempDir -Recurse -Force
    }
}
