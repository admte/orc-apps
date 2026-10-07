$ErrorActionPreference = 'Stop'

# Removes the SDK tree this app created. It is entirely ours — the command-line
# tools, the accepted licences, and whatever components builds added underneath.
# The temporary JDK the install phase may have used was deleted when that phase
# ended; nothing else was put on the node.

function Write-Note($message) {
	Write-Host "android-sdk uninstall: $message"
}

if (-not $env:ANDROID_SDK_INSTALL_ROOT -and -not $env:ProgramData) {
	throw 'android-sdk uninstall: ProgramData is required'
}
$sdkRoot = if ($env:ANDROID_SDK_INSTALL_ROOT) {
	$env:ANDROID_SDK_INSTALL_ROOT
} else {
	Join-Path $env:ProgramData 'android-sdk'
}

if (Test-Path -LiteralPath $sdkRoot) {
	Remove-Item -LiteralPath $sdkRoot -Recurse -Force
	Write-Note "removed the SDK at $sdkRoot"
} else {
	Write-Note "no SDK to remove dir=$sdkRoot"
}
