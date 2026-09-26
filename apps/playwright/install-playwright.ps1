$ErrorActionPreference = 'Stop'

# Windows needs far less than Linux: the browser builds carry their own
# libraries, and the only missing piece is the Media Feature Pack that
# Chromium's codecs depend on — absent from Windows Server and from N and KN
# editions. Playwright installs it through its own script, so the same command
# serves both platforms.

# Node line used only when the node has no Node.js of its own. Playwright needs
# 22 or newer; this is the oldest line it supports.
$NodeLine = if ($env:NODE_LINE) { $env:NODE_LINE } else { 'latest-v22.x' }
$NodeDist = if ($env:NODE_DIST) { $env:NODE_DIST } else { 'https://nodejs.org/dist' }

function Write-Note($message) {
	Write-Host "playwright install: $message"
}

if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
	throw "playwright install: Playwright supports Windows on x64 only; this node is $env:PROCESSOR_ARCHITECTURE"
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) "playwright-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $work -Force | Out-Null

try {
	# Playwright's installer is Node software, so something has to run it. If the
	# node already carries Node.js, that. Otherwise a copy is fetched here and
	# thrown away with this directory — the app must work when it is the only one
	# an operator picked, and nothing orders it after another app.
	if (Get-Command npx -ErrorAction SilentlyContinue) {
		Write-Note 'using the Node.js already on this node'
	} else {
		Write-Note 'no Node.js on this node; fetching a temporary one for Playwright''s installer'
		$sums = Join-Path $work 'SHASUMS256.txt'
		Invoke-WebRequest -UseBasicParsing -Uri "$NodeDist/$NodeLine/SHASUMS256.txt" -OutFile $sums

		$asset = $null
		$expected = $null
		foreach ($line in (Get-Content -LiteralPath $sums)) {
			$fields = $line.Trim() -split '\s+', 2
			if ($fields.Count -ne 2) { continue }
			$name = $fields[1].TrimStart('*')
			if ($name -like 'node-v*-win-x64.zip') {
				$asset = $name
				$expected = $fields[0]
				break
			}
		}
		if (-not $asset) {
			throw "playwright install: no Node.js build for win-x64 in $NodeLine"
		}

		$archive = Join-Path $work $asset
		Invoke-WebRequest -UseBasicParsing -Uri "$NodeDist/$NodeLine/$asset" -OutFile $archive
		$actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash
		if ($actual.ToLowerInvariant() -ne $expected.ToLowerInvariant()) {
			throw "playwright install: checksum verification failed for $asset"
		}

		Expand-Archive -LiteralPath $archive -DestinationPath $work -Force
		$nodeDir = Join-Path $work ($asset -replace '\.zip$', '')
		if (-not (Test-Path -LiteralPath (Join-Path $nodeDir 'npx.cmd') -PathType Leaf)) {
			throw "playwright install: the temporary Node.js does not provide npx"
		}
		$env:PATH = "$nodeDir;$env:PATH"
		Write-Note 'the temporary Node.js will be removed when this phase ends'
	}

	Write-Note 'installing the browser dependencies through Playwright'
	& npx --yes playwright install-deps
	if ($LASTEXITCODE -ne 0) {
		throw 'playwright install: could not install the browser dependencies; see the output above'
	}
} finally {
	Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

# A cache the jobs share, so the browsers of a given Playwright version are
# downloaded once on this node rather than once per job. Nothing is put here
# now: Playwright stores each version's builds in its own subdirectory, so the
# first job of a version fills it and the rest read it.
$cacheDir = if ($env:PLAYWRIGHT_CACHE_DIR) {
	$env:PLAYWRIGHT_CACHE_DIR
} else {
	Join-Path $env:ProgramData 'ms-playwright'
}
New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null

# By SID, not by name: the BUILTIN\Users group is called something else on a
# localized Windows, and S-1-5-32-545 is the same everywhere.
& icacls $cacheDir /grant '*S-1-5-32-545:(OI)(CI)M' | Out-Null
if ($LASTEXITCODE -ne 0) {
	throw "playwright install: could not grant write access to $cacheDir"
}

Write-Note 'the node can run Playwright browsers'
Write-Note "shared browser cache: $cacheDir - set PLAYWRIGHT_BROWSERS_PATH to it in the job to reuse downloads"
