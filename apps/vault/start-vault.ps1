<#
.SYNOPSIS
Checks that the Vault CLI is installed and, given an AppRole role ID, signs it in.

.DESCRIPTION
With -RoleIdFile it logs in with AppRole and stores the token for the vault command.

.PARAMETER Addr
Vault server URL, set as VAULT_ADDR for the vault CLI.

.PARAMETER RoleIdFile
File holding the AppRole role ID.

.PARAMETER SecretIdFile
File holding the AppRole secret ID, for roles that require one; needs -RoleIdFile.

.PARAMETER InstallDir
Where install put vault.exe, looked in when vault is not on PATH; defaults to
%LOCALAPPDATA%\Programs\Vault.
#>
[CmdletBinding()]
param(
    [string]$Addr = '',
    [string]$RoleIdFile = '',
    [string]$SecretIdFile = '',
    [string]$InstallDir = ''
)

$ErrorActionPreference = "Stop"

# The vault CLI reads the server address from VAULT_ADDR.
if ($Addr) {
    $env:VAULT_ADDR = $Addr
}

function Read-CredentialFile([string]$Path) {
    if (-not $Path) {
        return ''
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "vault configure: credential file is not readable"
    }
    return ([System.IO.File]::ReadAllText($Path)).TrimEnd([char[]]"`r`n")
}

$vaultCommand = Get-Command vault -ErrorAction SilentlyContinue
if ($vaultCommand) {
    $vaultExe = $vaultCommand.Source
} else {
    if (-not $InstallDir) {
        $InstallDir = Join-Path $env:LOCALAPPDATA "Programs\Vault"
    }
    $vaultExe = Join-Path $InstallDir "vault.exe"
}
if (-not (Test-Path -LiteralPath $vaultExe -PathType Leaf)) {
    throw "vault configure: vault CLI is not installed"
}

$roleId = Read-CredentialFile $RoleIdFile
$secretId = Read-CredentialFile $SecretIdFile

if (-not $roleId -and $secretId) {
    throw "vault configure: -RoleIdFile is required when -SecretIdFile is given"
}

if (-not $roleId) {
    Write-Host "Vault CLI is ready; AppRole credentials were not provided"
    exit 0
}

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "vault-auth-$([guid]::NewGuid())"
try {
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    $roleIdPath = Join-Path $tempDir "role-id"
    $secretIdPath = Join-Path $tempDir "secret-id"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($roleIdPath, $roleId, $utf8NoBom)
    $loginArgs = @("write", "-field=token", "auth/approle/login", "role_id=@$roleIdPath")
    if ($secretId) {
        [System.IO.File]::WriteAllText($secretIdPath, $secretId, $utf8NoBom)
        $loginArgs += "secret_id=@$secretIdPath"
    }
    $roleId = $null
    $secretId = $null

    Write-Host "Authenticating Vault CLI with AppRole"
    $token = & $vaultExe @loginArgs
    if ($LASTEXITCODE -ne 0 -or -not $token) {
        throw "vault configure: AppRole authentication failed"
    }

    $token | & $vaultExe login -no-print - | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "vault configure: could not store the Vault token"
    }
    $token = $null

    Write-Host "Vault CLI AppRole authentication complete"
} finally {
    if (Test-Path $tempDir) {
        Remove-Item -Path $tempDir -Recurse -Force
    }
}
