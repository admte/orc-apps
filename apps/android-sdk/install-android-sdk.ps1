$ErrorActionPreference = 'Stop'

# Installs the SDK command-line tools and accepts the licences, so that a build
# can ask sdkmanager for the components it pins without anyone answering a
# prompt. The components themselves are the build's business.

$Repo = if ($env:ANDROID_SDK_REPO) { $env:ANDROID_SDK_REPO } else { 'https://dl.google.com/android/repository' }
$IndexName = if ($env:ANDROID_SDK_INDEX) { $env:ANDROID_SDK_INDEX } else { 'repository2-3.xml' }
# Used only when the node carries no usable Java of its own.
$JdkFeature = if ($env:ANDROID_SDK_JDK_FEATURE) { $env:ANDROID_SDK_JDK_FEATURE } else { '21' }
# cmdline-tools is compiled for 17; anything older cannot run it at all.
$JdkMinimum = if ($env:ANDROID_SDK_JDK_MINIMUM) { $env:ANDROID_SDK_JDK_MINIMUM } else { '17' }
$Adoptium = if ($env:ANDROID_SDK_ADOPTIUM_API) { $env:ANDROID_SDK_ADOPTIUM_API } else { 'https://api.adoptium.net/v3' }

function Write-Note($message) {
	Write-Host "android-sdk install: $message"
}

# ARCHITEW6432 is set when a 32-bit process runs on a 64-bit machine, where
# PROCESSOR_ARCHITECTURE alone would say x86 and reject a supported node.
$architecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
if ($architecture -ne 'AMD64') {
	throw "android-sdk install: the Android SDK publishes x86-64 builds only; this node is $architecture"
}

$identity = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
	throw 'android-sdk install: must run with administrative rights: the SDK is installed system-wide'
}

if (-not $env:ANDROID_SDK_INSTALL_ROOT -and -not $env:ProgramData) {
	throw 'android-sdk install: ProgramData is required'
}
$sdkRoot = if ($env:ANDROID_SDK_INSTALL_ROOT) {
	$env:ANDROID_SDK_INSTALL_ROOT
} else {
	Join-Path $env:ProgramData 'android-sdk'
}

# The java sdkmanager will actually run: its launcher prefers JAVA_HOME and only
# falls back to PATH, so checking whatever PATH holds would pass a node whose
# JAVA_HOME points at an older JDK.
function Get-JavaBinary {
	if ($env:JAVA_HOME -and (Test-Path -LiteralPath (Join-Path $env:JAVA_HOME 'bin\java.exe') -PathType Leaf)) {
		return Join-Path $env:JAVA_HOME 'bin\java.exe'
	}
	$onPath = Get-Command java -ErrorAction SilentlyContinue
	if ($onPath) { return $onPath.Source }
	return $null
}

# `java -version` writes to stderr, and merging that into the success stream
# while ErrorActionPreference is Stop makes a NativeCommandError terminating —
# which would kill the phase on every node that has a Java at all. So the
# preference is lowered for exactly this call, the way the `java` app does it.
function Get-JavaMajor($binary) {
	$previous = $ErrorActionPreference
	try {
		$ErrorActionPreference = 'Continue'
		$output = (& $binary -version 2>&1 | Out-String)
	} finally {
		$ErrorActionPreference = $previous
	}
	# Not the first line: a node with JAVA_TOOL_OPTIONS set prints a
	# "Picked up ..." line before the version. Java 8 reports 1.8.0_x, which
	# yields 1 and is correctly rejected.
	if ($output -match 'version "(\d+)') { return [int]$Matches[1] }
	return 0
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) "android-sdk-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $work -Force | Out-Null
$toolsRoot = Join-Path $sdkRoot 'cmdline-tools'
$staged = Join-Path $toolsRoot 'latest.new'
$unpacked = Join-Path $toolsRoot 'unpack.tmp'

try {
	$javaBinary = Get-JavaBinary
	$javaMajor = if ($javaBinary) { Get-JavaMajor $javaBinary } else { 0 }

	if ($javaMajor -ge [int]$JdkMinimum) {
		Write-Note "using the Java already on this node: $javaBinary (major $javaMajor)"
	} else {
		if ($javaBinary) {
			Write-Note "the Java on this node is too old for the command-line tools: $javaBinary is $javaMajor, need $JdkMinimum"
		}
		Write-Note "fetching a temporary JDK $JdkFeature for sdkmanager"
		$next = [int]$JdkFeature + 1
		$selector = 'os=windows&architecture=x64&image_type=jdk&jvm_impl=hotspot&heap_size=normal&vendor=eclipse&project=jdk'
		$names = Invoke-RestMethod -UseBasicParsing `
			-Uri "$Adoptium/info/release_names?release_type=ga&version=%5B$JdkFeature,$next%29&$selector&page_size=1&sort_method=DEFAULT&sort_order=DESC"
		$release = @($names.releases)[0]
		# Validated before it is interpolated into a download URL, exactly as the
		# Unix half and the `java` app do.
		if (-not $release -or $release -notmatch '^jdk-\d+(\.\d+)*\+') {
			throw "android-sdk install: Adoptium publishes no usable JDK $JdkFeature release for windows/x64"
		}

		$jdkZip = Join-Path $work 'jdk.zip'
		Invoke-WebRequest -UseBasicParsing -OutFile $jdkZip `
			-Uri "$Adoptium/binary/version/$release/windows/x64/jdk/hotspot/normal/eclipse?project=jdk"
		# The endpoint serves a `sha256sum` line — digest, spaces, filename — so
		# the first field is the digest, and its shape is checked before it is
		# trusted.
		$checksumBody = (Invoke-WebRequest -UseBasicParsing `
				-Uri "$Adoptium/checksum/version/$release/windows/x64/jdk/hotspot/normal/eclipse?project=jdk").Content
		$expected = ((([string]$checksumBody).Trim() -split '\s+')[0]).ToLowerInvariant()
		if ($expected -notmatch '^[0-9a-f]{64}$') {
			throw "android-sdk install: Adoptium published no usable checksum for $release"
		}
		$actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $jdkZip).Hash
		if ($actual.ToLowerInvariant() -ne $expected) {
			throw "android-sdk install: checksum verification failed for the temporary JDK $release"
		}

		$jdkDir = Join-Path $work 'jdk'
		Expand-Archive -LiteralPath $jdkZip -DestinationPath $jdkDir -Force
		# The directory that actually holds java.exe, not simply the first one.
		$javaExe = Get-ChildItem -LiteralPath $jdkDir -Directory |
			ForEach-Object { Join-Path $_.FullName 'bin\java.exe' } |
			Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
			Select-Object -First 1
		if (-not $javaExe) {
			throw 'android-sdk install: the temporary JDK does not provide java.exe'
		}
		# Set, not prepended: a stale JAVA_HOME would otherwise still win, because
		# sdkmanager reads it before PATH.
		$javaBin = Split-Path -Parent $javaExe
		$env:JAVA_HOME = Split-Path -Parent $javaBin
		$env:PATH = "$javaBin;$env:PATH"
		Write-Note 'the temporary JDK will be removed when this phase ends'
	}

	# The archive Google currently publishes, read from the index sdkmanager
	# itself uses: the build number lives in the filename and changes, so there
	# is no stable URL to hard-code.
	Write-Note 'reading the SDK repository index'
	$indexFile = Join-Path $work 'index.xml'
	Invoke-WebRequest -UseBasicParsing -Uri "$Repo/$IndexName" -OutFile $indexFile
	# Loaded from the file, not through Get-Content: that decodes with the ANSI
	# code page, and a UTF-8 licence body would then arrive as mojibake or as a
	# character XML rejects. XmlDocument.Load honours the document's declaration.
	$indexDoc = New-Object System.Xml.XmlDocument
	$indexDoc.Load($indexFile)

	$archive = $null
	foreach ($package in $indexDoc.GetElementsByTagName('remotePackage')) {
		if ($package.path -ne 'cmdline-tools;latest') { continue }
		foreach ($candidate in $package.archives.archive) {
			if ($candidate.'host-os' -ne 'windows') { continue }
			$arch = $candidate.'host-arch'
			if ($arch -and $arch -ne 'x64') { continue }
			$archive = $candidate
			break
		}
		if ($archive) { break }
	}
	if (-not $archive) {
		throw 'android-sdk install: the repository index lists no windows build of cmdline-tools;latest'
	}

	$asset = [string]$archive.complete.url
	$digestType = if ($archive.complete.checksum.type) { [string]$archive.complete.checksum.type } else { 'sha1' }
	$expected = $archive.complete.checksum.'#text'
	if (-not $expected) { $expected = $archive.complete.checksum }
	$expected = ([string]$expected).Trim()
	if (-not $asset -or $expected -notmatch '^[0-9a-fA-F]{40}$') {
		throw 'android-sdk install: the repository index gave no usable archive for windows'
	}
	if ($digestType -ne 'sha1') {
		throw "android-sdk install: the repository index publishes a $digestType checksum, which this script does not verify"
	}

	Write-Note "downloading $asset"
	$zip = Join-Path $work $asset
	Invoke-WebRequest -UseBasicParsing -Uri "$Repo/$asset" -OutFile $zip
	$actual = (Get-FileHash -Algorithm SHA1 -LiteralPath $zip).Hash
	if ($actual.ToLowerInvariant() -ne $expected.ToLowerInvariant()) {
		throw "android-sdk install: checksum verification failed for $asset"
	}

	# Unpacked inside the SDK tree rather than under TEMP: Move-Item on a
	# directory refuses to cross volumes, and TEMP is often on another one. The
	# archive unpacks to a `cmdline-tools` directory, and sdkmanager insists on
	# living at <sdk>\cmdline-tools\latest\bin, so the contents move one level
	# down — and the live copy is replaced only once the new one is complete.
	New-Item -ItemType Directory -Path $toolsRoot -Force | Out-Null
	foreach ($leftover in @($staged, $unpacked)) {
		if (Test-Path -LiteralPath $leftover) {
			Remove-Item -LiteralPath $leftover -Recurse -Force
		}
	}
	Expand-Archive -LiteralPath $zip -DestinationPath $unpacked -Force
	$tools = Join-Path $unpacked 'cmdline-tools'
	if (-not (Test-Path -LiteralPath (Join-Path $tools 'bin\sdkmanager.bat') -PathType Leaf)) {
		throw "android-sdk install: $asset does not contain cmdline-tools\bin\sdkmanager.bat"
	}
	Move-Item -LiteralPath $tools -Destination $staged
	Remove-Item -LiteralPath $unpacked -Recurse -Force

	$latest = Join-Path $toolsRoot 'latest'
	if (Test-Path -LiteralPath $latest) {
		Remove-Item -LiteralPath $latest -Recurse -Force
	}
	Move-Item -LiteralPath $staged -Destination $latest

	$sdkmanager = Join-Path $latest 'bin\sdkmanager.bat'
	if (-not (Test-Path -LiteralPath $sdkmanager -PathType Leaf)) {
		throw "android-sdk install: sdkmanager is missing after unpacking: $sdkmanager"
	}

	# Every licence, accepted once, with administrative rights. This is the half
	# a build cannot do: the prompt is interactive and the answers are written
	# into a directory it may not own. PowerShell has no `yes`, so the answers
	# are a fixed run far above the handful Google ships — and the result is
	# counted below rather than assumed.
	Write-Note 'accepting the SDK licences'
	$accept = 1..500 | ForEach-Object { 'y' }
	$accept | & $sdkmanager "--sdk_root=$sdkRoot" --licenses | Out-Null
	if ($LASTEXITCODE -ne 0) {
		throw 'android-sdk install: could not accept the SDK licences'
	}

	# --licenses reports success and writes nothing when it cannot reach the
	# repository to enumerate them, and the first build is then stopped by the
	# very prompt this phase exists to answer.
	$licenceDir = Join-Path $sdkRoot 'licenses'
	$accepted = @(Get-ChildItem -LiteralPath $licenceDir -File -ErrorAction SilentlyContinue)
	if ($accepted.Count -eq 0) {
		throw "android-sdk install: no licences were written to $licenceDir; the tools could not reach the SDK repository"
	}
	Write-Note "$($accepted.Count) licences accepted in $licenceDir"

	# The tree is opened so a build can install the components it pins. The grant
	# is inheritable, which means it also reaches the two directories that must
	# stay read-only — so inheritance is switched off on those and they are
	# granted read and execute alone. Without this a build could replace
	# sdkmanager, which the next install phase then runs as an administrator.
	& icacls $sdkRoot /grant '*S-1-5-32-545:(OI)(CI)M' | Out-Null
	if ($LASTEXITCODE -ne 0) {
		throw "android-sdk install: could not grant write access to $sdkRoot"
	}
	foreach ($protected in @($toolsRoot, $licenceDir)) {
		& icacls $protected /inheritance:r | Out-Null
		if ($LASTEXITCODE -ne 0) {
			throw "android-sdk install: could not protect $protected"
		}
		& icacls $protected /grant '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /T | Out-Null
		if ($LASTEXITCODE -ne 0) {
			throw "android-sdk install: could not set permissions on $protected"
		}
	}

	# Same stderr guard as the version check above: sdkmanager reports through
	# stderr when the JVM cannot start, which is exactly the case to catch.
	$previous = $ErrorActionPreference
	try {
		$ErrorActionPreference = 'Continue'
		$output = (& $sdkmanager "--sdk_root=$sdkRoot" --version 2>&1 | Out-String)
		$status = $LASTEXITCODE
	} finally {
		$ErrorActionPreference = $previous
	}
	if ($status -ne 0) {
		throw "android-sdk install: sdkmanager does not run after installation: $($output.Trim())"
	}
	$version = ($output -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1).Trim()
	Write-Note "command-line tools $version installed at $sdkRoot"
	Write-Note "set ANDROID_HOME=$sdkRoot in the build to use them"
} finally {
	Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
	Remove-Item -LiteralPath $staged -Recurse -Force -ErrorAction SilentlyContinue
	Remove-Item -LiteralPath $unpacked -Recurse -Force -ErrorAction SilentlyContinue
}
