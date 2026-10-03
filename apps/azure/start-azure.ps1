$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'azure-common.ps1')

# Signs the Azure CLI in as a service principal, if one was given. Without
# credentials the CLI is simply left ready and unauthenticated — the same
# behaviour aws and gcloud have when their optional parameters are empty.

function Read-Param([string] $value, [string] $file) {
	# A parameter arrives either as a value or, when it is marked sensitive, as
	# a file the platform wrote. ReadAllText rather than Get-Content -Raw: the
	# latter returns $null for an empty file, and the caller's "provided but
	# empty" message would never be reached. It also defaults to UTF-8, where
	# Get-Content in Windows PowerShell 5.1 would use the ANSI code page.
	if ($file) {
		if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
			throw "azure configure: credential file is not readable: $file"
		}
		return ([System.IO.File]::ReadAllText($file)).TrimEnd([char[]]"`r`n")
	}
	return $value
}

# This app's own install comes first, as on Linux: install declines to take over
# an Azure CLI somebody else put there, so looking at the PATH first could sign
# that other CLI in instead.
$az = $null
$known = Get-AzPath
if (Test-Path -LiteralPath $known -PathType Leaf) {
	$az = $known
} else {
	$found = Get-Command az -ErrorAction SilentlyContinue
	if ($found) { $az = $found.Source }
}
if (-not $az) {
	throw 'azure configure: Azure CLI is not installed'
}

# Every sibling verifies the binary right after finding it. Without this a
# broken install would report success here.
$env:AZURE_CORE_COLLECT_TELEMETRY = 'false'
$probe = Invoke-Native { & $az version }
if ($probe.ExitCode -ne 0) {
	throw "azure configure: the Azure CLI at $az does not run: $($probe.Output)"
}

$clientId = Read-Param $env:AZURE_CLIENT_ID $env:AZURE_CLIENT_ID_FILE
$clientSecret = Read-Param $env:AZURE_CLIENT_SECRET $env:AZURE_CLIENT_SECRET_FILE
$tenantId = Read-Param $env:AZURE_TENANT_ID $env:AZURE_TENANT_ID_FILE

$given = @(
	$env:AZURE_CLIENT_ID, $env:AZURE_CLIENT_ID_FILE,
	$env:AZURE_CLIENT_SECRET, $env:AZURE_CLIENT_SECRET_FILE,
	$env:AZURE_TENANT_ID, $env:AZURE_TENANT_ID_FILE
) | Where-Object { $_ }

if (-not $given) {
	Write-Host 'azure configure: Azure CLI is ready; credentials were not provided'
	exit 0
}

# One of the three was filled in, so the other two are wanted too — and naming
# the one that is missing beats "provide them together", which leaves the
# operator to work out which of three fields it means.
if (-not $clientId) { throw 'azure configure: azure_client_id is required once any of the three credentials is given' }
if (-not $clientSecret) { throw 'azure configure: azure_client_secret is required once any of the three credentials is given' }
if (-not $tenantId) { throw 'azure configure: azure_tenant_id is required once any of the three credentials is given' }

# azure-cli rewrites any argument whose first character is '@' into the contents
# of the file it names — before the arguments are parsed, for every option. An
# identifier starting with '@' would send a file's contents to Microsoft as a
# client ID, and the rejection would carry them into this log.
#
# \z and not $: in .NET, $ also matches before a trailing newline, which would
# let a value through that the Unix half rejects.
if ($clientId -notmatch '^[0-9A-Za-z-]+\z') {
	throw 'azure configure: azure_client_id is not a valid identifier'
}
if ($tenantId -notmatch '^[0-9A-Za-z.-]+\z') {
	throw 'azure configure: azure_tenant_id is not a valid identifier or domain'
}

# The CLI keeps its sign-in state here, and it writes the service principal's
# secret into it. Left where the CLI expects it, but the directory is given an
# explicit access list: Windows has no umask, and a directory outside the user
# profile — which AZURE_CONFIG_DIR can name — inherits whatever its parent
# allows. The Unix half sets umask 077 for the same reason.
$configDir = $env:AZURE_CONFIG_DIR
if (-not $configDir) {
	if (-not $env:USERPROFILE) {
		throw 'azure configure: USERPROFILE is required to sign the Azure CLI in'
	}
	$configDir = Join-Path $env:USERPROFILE '.azure'
}
New-Item -ItemType Directory -Path $configDir -Force | Out-Null

$acl = Get-Acl -LiteralPath $configDir
$acl.SetAccessRuleProtection($true, $false)
foreach ($existing in @($acl.Access)) { $acl.RemoveAccessRule($existing) | Out-Null }
foreach ($who in @([Security.Principal.WindowsIdentity]::GetCurrent().User,
		(New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'))) {
	$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
				$who, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
}
Set-Acl -LiteralPath $configDir -AclObject $acl
$env:AZURE_CONFIG_DIR = $configDir

Write-Host "azure configure: signing in as service principal $clientId"

# `--password @-` makes the CLI read the secret from standard input: the `@`
# prefix is expanded by azure-cli-core before the arguments are parsed, and `-`
# means stdin. The secret therefore never appears in the command line of any
# process.
#
# $OutputEncoding governs what a pipeline delivers to a native command, and in
# Windows PowerShell 5.1 it defaults to ASCII, which would mangle any byte above
# 127 in a secret.
$OutputEncoding = New-Object Text.UTF8Encoding $false
$login = Invoke-Native {
	$clientSecret | & $az login `
		--service-principal `
		--username $clientId `
		--password '@-' `
		--tenant $tenantId
}
$clientSecret = $null
if ($login.ExitCode -ne 0) {
	# Safe to log: the secret arrived on standard input, azure-cli replaces
	# every option value with a placeholder in its own logs, and its sign-in
	# errors name the application, never the credential.
	throw "azure configure: could not sign in as $clientId - check the secret and the tenant: $($login.Output)"
}

Write-Host 'azure configure: Azure CLI signed in'
