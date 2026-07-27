$ErrorActionPreference = "Stop"

function Get-OrcParameter {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    $value = [Environment]::GetEnvironmentVariable($Name)
    $file = [Environment]::GetEnvironmentVariable("${Name}_FILE")
    if ($file) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "vault configure: credential file is not readable"
        }
        return ([System.IO.File]::ReadAllText($file)).TrimEnd([char[]]"`r`n")
    }
    return $value
}

$vaultCommand = Get-Command vault -ErrorAction SilentlyContinue
if ($vaultCommand) {
    $vaultExe = $vaultCommand.Source
} else {
    $installDir = if ($env:VAULT_INSTALL_DIR) {
        $env:VAULT_INSTALL_DIR
    } else {
        Join-Path $env:LOCALAPPDATA "Programs\Vault"
    }
    $vaultExe = Join-Path $installDir "vault.exe"
}
if (-not (Test-Path -LiteralPath $vaultExe -PathType Leaf)) {
    throw "vault configure: vault CLI is not installed"
}

$roleId = Get-OrcParameter -Name "VAULT_ROLE_ID"
$secretId = Get-OrcParameter -Name "VAULT_SECRET_ID"

if (-not $roleId -and $secretId) {
    throw "vault configure: vault_role_id is required when vault_secret_id is provided"
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
