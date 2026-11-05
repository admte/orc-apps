#!/bin/sh
set -eu

usage() {
	cat <<'USAGE'
Usage: start-shell.sh [--dir=DIR] [--cmd-file=PATH]

Runs the POSIX shell script in PATH with sh, from DIR.

  --dir=DIR        directory to run the command in; when missing or empty, the
                   command runs in the current directory
  --cmd-file=PATH  file holding the command to run; when missing, nothing runs
  --help           show this help
USAGE
}

dir=
cmd_file=
for arg; do
	case $arg in
	--dir=*) dir=${arg#--dir=} ;;
	--cmd-file=*) cmd_file=${arg#--cmd-file=} ;;
	--help)
		usage
		exit 0
		;;
	*)
		echo "unknown argument $arg" >&2
		usage >&2
		exit 2
		;;
	esac
done

if [ -n "$cmd_file" ]; then
	[ -r "$cmd_file" ] || {
		echo "command file $cmd_file is not readable" >&2
		exit 1
	}
	# A relative path names a file in the starting directory, not in DIR.
	case $cmd_file in
	/*) ;;
	*) cmd_file=$(pwd)/$cmd_file ;;
	esac
fi

if [ -n "$dir" ]; then
	[ -d "$dir" ] || {
		echo "working directory $dir does not exist" >&2
		exit 1
	}
	cd -- "$dir"
fi

if [ -z "$cmd_file" ]; then
	echo "no command given; nothing to run"
	exit 0
fi

exec sh "$cmd_file"
