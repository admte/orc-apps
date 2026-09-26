$ErrorActionPreference = 'Stop'

# Removes what this app created, and only that: the shared browser cache. The
# Media Feature Pack stays — it is a Windows capability, shared with everything
# else on the node.

function Write-Note($message) {
	Write-Host "playwright uninstall: $message"
}

$cacheDir = if ($env:PLAYWRIGHT_CACHE_DIR) {
	$env:PLAYWRIGHT_CACHE_DIR
} else {
	Join-Path $env:ProgramData 'ms-playwright'
}

if (Test-Path -LiteralPath $cacheDir) {
	Remove-Item -LiteralPath $cacheDir -Recurse -Force
	Write-Note "removed the shared browser cache $cacheDir"
} else {
	Write-Note "no shared browser cache to remove dir=$cacheDir"
}

Write-Note 'the Media Feature Pack is left in place; it is a shared Windows capability'
