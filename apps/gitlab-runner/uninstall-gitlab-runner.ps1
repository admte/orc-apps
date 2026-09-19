$ErrorActionPreference = 'Stop'

# Removal of the app itself. The runner has already stopped, and the stopped hook
# deleted it from GitLab when the node was terminating; deleting again here is
# best-effort, for the case where the app is taken off a node that keeps running.

function Write-Note($message) {
	Write-Host "gitlab-runner uninstall: $message"
}

function Get-TokenValue {
	if ($env:TOKEN_FILE) {
		return (Get-Content -Raw -LiteralPath $env:TOKEN_FILE).Trim()
	}
	if ($env:TOKEN) {
		return $env:TOKEN.Trim()
	}
	return $null
}

function Get-RunnerId($path) {
	if (-not (Test-Path -LiteralPath $path)) { return $null }
	$value = Get-Content -Raw -LiteralPath $path
	if (-not $value) { return $null }
	$value = $value.Trim()
	if (-not $value) { return $null }
	return $value
}

if (-not $env:APP_VERSION) {
	throw 'gitlab-runner uninstall: APP_VERSION is required'
}
if ($env:APP_VERSION -notmatch '^\d+\.\d+\.\d+$') {
	throw "gitlab-runner uninstall: invalid APP_VERSION: $env:APP_VERSION"
}

$root = Join-Path $env:ProgramFiles 'gitlab-runner'
$prefix = Join-Path $root $env:APP_VERSION
$current = Join-Path $root 'current'
$workDir = Join-Path (Get-Location) 'gitlab-runner'
$config = Join-Path $workDir 'config.toml'
$idFile = Join-Path $workDir 'runner.id'

$deleted = $false
$runnerId = Get-RunnerId $idFile
if ($runnerId) {
	$token = Get-TokenValue
	if (-not $token -or -not $env:URL -or -not $env:URL.StartsWith('https://')) {
		Write-Note "no usable URL or access token; leaving the runner in GitLab id=$runnerId"
	} else {
		$uri = [uri]$env:URL
		try {
			Invoke-RestMethod -Method Delete -Headers @{ 'PRIVATE-TOKEN' = $token } `
				-Uri "$($uri.Scheme)://$($uri.Authority)/api/v4/runners/$runnerId" | Out-Null
			$deleted = $true
			Write-Note "runner deleted id=$runnerId"
		} catch {
			Write-Note "could not delete the runner; removing the install anyway id=$runnerId"
		}
	}
}

# Only an exposure that still points into this version's own tree is ours to
# remove: after an upgrade it belongs to the version that replaced this one.
if (Test-Path -LiteralPath $current) {
	$item = Get-Item -LiteralPath $current -Force
	if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
		$target = @($item.Target) | Select-Object -First 1
		if ($target) {
			$target = ([string]$target).TrimEnd('\')
			if ($target -eq $prefix.TrimEnd('\')) {
				[IO.Directory]::Delete($current)
			}
		}
	}
}

Remove-Item -LiteralPath $prefix -Recurse -Force -ErrorAction SilentlyContinue

if ((Test-Path -LiteralPath $root) -and -not (Test-Path -LiteralPath $current)) {
	$remaining = @(Get-ChildItem -LiteralPath $root -Force)
	if ($remaining.Count -eq 0) {
		$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
		$entries = @($machinePath -split ';' | Where-Object {
			$_ -and $_.TrimEnd('\') -ne $current.TrimEnd('\')
		})
		[Environment]::SetEnvironmentVariable('Path', $entries -join ';', 'Machine')
		Remove-Item -LiteralPath $root -Force
		# The app's own state goes only once the last version is gone, so removing
		# one of two installed versions does not disarm the one still running.
		if ($deleted) {
			Remove-Item -LiteralPath $idFile -Force -ErrorAction SilentlyContinue
		}
		Remove-Item -LiteralPath $config -Force -ErrorAction SilentlyContinue
		Remove-Item -LiteralPath (Join-Path $workDir 'builds') -Recurse -Force -ErrorAction SilentlyContinue
		Write-Note 'removed the last version; cleared the runner configuration'
	}
}

Write-Note "removed version=$($env:APP_VERSION) dir=$prefix"
