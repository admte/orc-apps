$ErrorActionPreference = 'Stop'

if (-not $env:APP_VERSION) {
	throw 'java uninstall: APP_VERSION is required'
}
if ($env:APP_VERSION -notmatch '^\d+\.\d+\.\d+$') {
	throw "java uninstall: invalid APP_VERSION: $env:APP_VERSION"
}

$root = Join-Path $env:ProgramFiles 'java'
$prefix = Join-Path $root $env:APP_VERSION
$current = Join-Path $root 'current'
$pathEntry = Join-Path $current 'bin'

if (Test-Path -LiteralPath $current) {
	$item = Get-Item -LiteralPath $current -Force
	if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
		$target = [IO.Path]::GetFullPath([string]$item.Target).TrimEnd('\')
		$owned = [IO.Path]::GetFullPath($prefix).TrimEnd('\')
		if ($target -eq $owned) {
			[IO.Directory]::Delete($current)
		}
	}
}

if (-not (Test-Path -LiteralPath $current)) {
	$javaHome = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'Machine')
	if ($javaHome -and $javaHome.TrimEnd('\') -eq $current.TrimEnd('\')) {
		[Environment]::SetEnvironmentVariable('JAVA_HOME', $null, 'Machine')
	}
}

Remove-Item -LiteralPath $prefix -Recurse -Force -ErrorAction SilentlyContinue

if ((Test-Path -LiteralPath $root) -and -not (Test-Path -LiteralPath $current)) {
	$remaining = @(Get-ChildItem -LiteralPath $root -Force)
	if ($remaining.Count -eq 0) {
		$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
		$entries = @($machinePath -split ';' | Where-Object {
			$_ -and $_.TrimEnd('\') -ne $pathEntry.TrimEnd('\')
		})
		[Environment]::SetEnvironmentVariable('Path', $entries -join ';', 'Machine')
		Remove-Item -LiteralPath $root -Force
	}
}
