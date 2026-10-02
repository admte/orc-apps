$ErrorActionPreference = 'Stop'

# Removes one version's tree, and the junction and PATH entry with it once nothing is
# left. Mirrors go's uninstall, including the ownership guard: a newer version installed
# alongside this one has already repointed the junction and keeps it.

if (-not $env:ProgramFiles) { throw 'trivy uninstall: ProgramFiles is required' }

$root = Join-Path $env:ProgramFiles 'trivy'
$current = Join-Path $root 'current'

$version = $env:APP_VERSION -replace '^v', ''
if ($version -and $version -notmatch '^\d+\.\d+\.\d+\z') {
	throw "trivy uninstall: invalid APP_VERSION: $env:APP_VERSION"
}

if (-not $version) {
	# The install ran without a resolved version and took the then-current release, so
	# the tree the junction points at is the one to remove.
	if (-not (Test-Path -LiteralPath $current)) {
		Write-Host 'trivy uninstall: no installed version to remove'
		exit 0
	}
	$item = Get-Item -LiteralPath $current -Force
	if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
		Write-Host "trivy uninstall: $current is not a junction; leaving it in place"
		exit 0
	}
	$version = Split-Path -Leaf ([string] $item.Target)
	Write-Host "trivy uninstall: no version was requested; removing $version, the version the junction points at"
}

$prefix = Join-Path $root $version

if (Test-Path -LiteralPath $current) {
	$item = Get-Item -LiteralPath $current -Force
	if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
		$target = [IO.Path]::GetFullPath([string] $item.Target).TrimEnd('\')
		$owned = [IO.Path]::GetFullPath($prefix).TrimEnd('\')
		if ($target -eq $owned) { [IO.Directory]::Delete($current) }
	}
}

Remove-Item -LiteralPath $prefix -Recurse -Force -ErrorAction SilentlyContinue

# The PATH entry goes only when this was the last version: it points at the junction, so
# it stays correct for any version that is still installed.
if ((Test-Path -LiteralPath $root) -and -not (Test-Path -LiteralPath $current)) {
	$remaining = @(Get-ChildItem -LiteralPath $root -Force)
	if ($remaining.Count -eq 0) {
		$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
		$entries = @($machinePath -split ';' | Where-Object {
				$_ -and $_.TrimEnd('\') -ne $current.TrimEnd('\')
			})
		[Environment]::SetEnvironmentVariable('Path', $entries -join ';', 'Machine')
		Remove-Item -LiteralPath $root -Force
	}
}
