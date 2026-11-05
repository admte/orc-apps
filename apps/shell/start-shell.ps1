<#
.SYNOPSIS
Runs the cmd.exe commands held in a file, from a working directory.

.DESCRIPTION
The file's content runs as a cmd.exe batch file, every line of it, without echoing each command;
the batch's exit code is this script's exit code.

.PARAMETER Dir
Directory to run the command in; when empty, the command runs in the current directory.

.PARAMETER CmdFile
File holding the cmd.exe commands to run; when empty, nothing runs.
#>
[CmdletBinding()]
param(
	[string]$Dir = '',
	[string]$CmdFile = ''
)

$ErrorActionPreference = 'Stop'

if ($CmdFile) {
	if (-not (Test-Path -LiteralPath $CmdFile -PathType Leaf)) {
		[Console]::Error.WriteLine("command file $CmdFile does not exist")
		exit 1
	}
	# A relative path names a file in the starting directory, not in -Dir.
	$CmdFile = (Resolve-Path -LiteralPath $CmdFile).ProviderPath
}

if ($Dir) {
	if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
		[Console]::Error.WriteLine("working directory $Dir does not exist")
		exit 1
	}
	Set-Location -LiteralPath $Dir
}

if (-not $CmdFile) {
	'no command given; nothing to run'
	exit 0
}

$command = [IO.File]::ReadAllText($CmdFile)
if (-not $command.Trim()) {
	'the command is empty; nothing to run'
	exit 0
}

# cmd.exe runs a file as a batch only when its name ends in .cmd or .bat, so the commands are
# copied into one, in a directory of this script's own that is removed afterwards. Batch lines end
# in CRLF; `@echo off` keeps cmd.exe from echoing each command before it runs.
$work = Join-Path ([IO.Path]::GetTempPath()) ('shell-' + [guid]::NewGuid().ToString('N'))
$batch = Join-Path $work 'command.cmd'
$exitCode = 1
try {
	New-Item -ItemType Directory -Path $work | Out-Null
	$text = "@echo off`r`n" + ($command -replace "`r?`n", "`r`n")
	[IO.File]::WriteAllText($batch, $text, (New-Object Text.UTF8Encoding $false))

	$start = New-Object System.Diagnostics.ProcessStartInfo
	$start.FileName = 'cmd.exe'
	# /s drops exactly the outer pair of quotes, leaving the quoted batch path.
	$start.Arguments = '/s /c ""' + $batch + '""'
	$start.UseShellExecute = $false
	$start.WorkingDirectory = (Get-Location).ProviderPath
	$process = [System.Diagnostics.Process]::Start($start)
	$process.WaitForExit()
	$exitCode = $process.ExitCode
} finally {
	Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
exit $exitCode
