#!/bin/sh
# resharun.sh - make an existing type-2 AppImage run against a glibc bundled
# inside the AppDir instead of the one of the host.
#
# This is the layout quick-sharun produces, applied to an AppImage that was
# built the normal way: the AppDir gets a copy of sharun, a lib/ with the
# glibc payload, a .bin/ with the real programs and a bin/ of hardlinks to
# sharun. Every executable is replaced by a hardlink to sharun, so running it
# re-enters sharun, which maps the bundled ld.so into the process with
# userland_execve and passes it --library-path. The PT_INTERP the program was
# linked with (an absolute path into the host) is never used, and the loader
# is patched so that it cannot read the host /etc/ld.so.cache either.
#
# usage: resharun.sh [-f] [-k] [-o OUT.AppImage] [-g GLIBC_DIR] APPIMAGE|APPDIR
#
#   -g GLIBC_DIR  glibc payload to inject: the usr/lib of an Arch glibc
#                 package (ld-linux*.so* + libc.so.6), see fetch-glibc.sh.
#                 Env: SHARUN_GLIBC
#   -o OUT        output AppImage (default: <name>-glibc.AppImage)
#   -f            go on even if the payload is older than what the binaries
#                 of the AppImage, or the libraries it takes from the host,
#                 require
#   -k            keep the unpacked AppDir for inspection
#   --smoke BIN   after building, run BIN (path inside the AppDir) with
#                 LD_DEBUG=libs and report where libc.so.6 came from

set -eu

PROG=${0##*/}
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
SHARUN=${SHARUN:-$(if [ -x "$SELF_DIR/sharun" ]; then
	echo "$SELF_DIR/sharun"; else command -v sharun || true; fi)}
UNSQUASHFS=${UNSQUASHFS:-$(command -v unsquashfs || true)}
MKSQUASHFS=${MKSQUASHFS:-$(command -v mksquashfs || true)}

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
info() { printf '* %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

usage() {
	sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0" >&2
	exit 1
}

_elf_field() { # $1 file, $2 field number
	"$SELF_DIR/elfinfo.py" "$1" | cut -f"$2"
}

_glibc_version() {
	_v=$(grep -ao 'release version [0-9][0-9.]*' "$1/libc.so.6" 2>/dev/null \
		| head -n1 || true)
	[ -n "$_v" ] || die "$1/libc.so.6: cannot read the glibc version"
	printf '%s\n' "${_v##* }" | sed 's/\.$//'
}

_ver_lt() {
	[ "$1" != "$2" ] &&
		[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

_extract() {
	# an executable is only found through PATH, so a bare relative name like
	# app.AppImage has to be made absolute before it can be run
	_img=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
	if [ ! -x "$_img" ]; then
		cp "$_img" "$WORK/in.AppImage"
		chmod +x "$WORK/in.AppImage"
		_img=$WORK/in.AppImage
	fi
	_off=$("$_img" --appimage-offset 2>/dev/null) || die "$1: not an AppImage"
	case $_off in ''|*[!0-9]*) die "$1: bad AppImage offset '$_off'" ;; esac

	head -c "$_off" "$_img" > "$WORK/runtime"
	"$UNSQUASHFS" -o "$_off" -d "$APPDIR" "$_img" >/dev/null \
		|| die "$1: unsquashfs failed"

	_sq=$("$UNSQUASHFS" -s -o "$_off" "$_img" 2>/dev/null)
	COMP=$(printf '%s\n' "$_sq" | sed -n 's/^Compression //p')
	BSIZE=$(printf '%s\n' "$_sq" | sed -n 's/^Block size //p')
	[ -n "$COMP" ] || COMP=gzip
	[ -n "$BSIZE" ] || BSIZE=131072
	info "squashfs: $COMP, block size $BSIZE, runtime $_off bytes"
}

# everything that would use the host loader if it was not routed
_inventory() {
	find "$APPDIR" -path "$APPDIR/lib" -prune -o -path "$APPDIR/.bin" -prune \
		-o -path "$APPDIR/bin" -prune -o -type f -perm -100 -print > "$WORK/files"
	# shellcheck disable=SC2046
	tr '\n' '\0' < "$WORK/files" | xargs -0 -r "$SELF_DIR/elfinfo.py" > "$WORK/info"
	awk -F'\t' -v c="$CLASS" '$5 != "-" && $2 == c {print $1}' "$WORK/info" \
		> "$WORK/execs"
	MAXNEED=$(awk -F'\t' '$8 != "-" {print $8}' "$WORK/info" | sort -Vu | tail -n1)
	[ -n "$MAXNEED" ] || MAXNEED=0
	info "$(wc -l < "$WORK/execs") ${CLASS}-bit executables, highest requirement GLIBC_$MAXNEED"
	if [ ! -s "$WORK/execs" ]; then
		if [ "$FORCE" = 1 ]; then
			warn "no dynamic executables, the AppImage does not use the host loader"
		else
			die "no dynamic executables to route, the AppImage does not use the host
loader and a bundled glibc would change nothing (-f forces)"
		fi
	fi

	if awk -F'\t' -v c="$CLASS" '$5 != "-" && $2 != c' "$WORK/info" | grep -q .; then
		warn "the AppDir has executables of another ELF class, they keep the host loader"
	fi

	for _f in libc.so.6 libc.musl-x86_64.so.1 ld-musl-x86_64.so.1; do
		_found=$(find "$APPDIR" -name "$_f" | head -n1)
		[ -z "$_found" ] || die "$APPDIR already ships $_found"
	done
}

# the directories of the AppImage that hold shared objects, colon separated,
# so that the loader of the host can find the bundled ones
_appdir_libdirs() {
	find "$APPDIR" -path "$APPDIR/lib" -prune -o -type d -print |
		while read -r _d; do
			set -- "$_d"/*.so*
			[ -e "$1" ] || continue
			printf '%s\n' "$_d"
		done | sort -u | tr '\n' ':'
}

# the libraries an AppImage does not carry keep coming from the host, and they
# were built against the glibc of the host. A payload older than the highest
# GLIBC_x.y among them cannot load them, which is the failure this tool is
# here to avoid, so measure it instead of guessing
_host_need() {
	_libdirs=$(_appdir_libdirs)
	while IFS='	' read -r _p _cls _mach _type _interp _runpath _needed _glibc; do
		[ "$_interp" = "-" ] && continue
		LD_LIBRARY_PATH=${_libdirs%:} ldd "$_p" 2>/dev/null |
			sed -n 's/.*=> \(\/[^ ]*\).*/\1/p'
	done < "$WORK/execs" | sort -u | grep -v "^$APPDIR/" |
		grep -v '/ld-linux\|/ld-musl\|/ld64' > "$WORK/hostlibs" || true
	HOSTNEED=0
	[ -s "$WORK/hostlibs" ] || return 0
	# shellcheck disable=SC2046
	tr '\n' '\0' < "$WORK/hostlibs" |
		xargs -0 -r "$SELF_DIR/elfinfo.py" > "$WORK/hostinfo"
	HOSTNEED=$(awk -F'\t' '$8 != "-" {print $8}' "$WORK/hostinfo" |
		sort -Vu | tail -n1)
	[ -n "$HOSTNEED" ] || HOSTNEED=0
	info "host libraries need up to GLIBC_$HOSTNEED"
}

_inject_glibc() {
	_src=$GLIBC
	_dst=$APPDIR/lib
	mkdir -p "$_dst"

	for _f in libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 \
		libutil.so.1 libresolv.so.2 libnss_dns.so.2 libnss_files.so.2 \
		libnss_compat.so.2 libnss_db.so.2 libnss_hesiod.so.2; do
		[ -f "$_src/$_f" ] && cp "$_src/$_f" "$_dst/$_f"
	done
	# some programs dlopen("libc.so"), which is only a linker script on Arch
	ln -sf libc.so.6 "$_dst/libc.so"

	_ld=
	for _n in ld-linux-x86-64.so.2 ld-linux-aarch64.so.1 ld-linux.so.2; do
		if [ -f "$_src/$_n" ]; then _ld=$_n; break; fi
	done
	[ -n "$_ld" ] || _ld=$(basename "$(ls "$_src"/ld-linux*.so* 2>/dev/null | head -n1)")
	[ -n "$_ld" ] || die "$_src: no dynamic loader found"
	cp "$_src/$_ld" "$_dst/$_ld"

	# the bundled loader must not read /etc: the host /etc/ld.so.cache would
	# resolve sonames to host libraries, /etc/ld.so.preload would map host
	# objects into the process
	if grep -qa '/etc' "$_dst/$_ld"; then
		sed -i -e 's|/etc|/KEK|g' "$_dst/$_ld"
		info "patched /etc out of $_ld"
	fi

	mkdir -p "$_dst/gconv"
	for _g in UTF ANSI CP LATIN UNICODE ISO8859 SJIS; do
		cp "$_src"/gconv/"$_g"*.so "$_dst"/gconv/ 2>/dev/null || true
	done
	for _g in EUC-JP EUC-KR EUC-CN; do
		cp "$_src"/gconv/"$_g".so "$_dst"/gconv/ 2>/dev/null || true
	done
	cp "$_src"/gconv/gconv-modules "$_dst"/gconv/ 2>/dev/null || true
	cp -r "$_src"/gconv/gconv-modules.d "$_dst"/gconv/ 2>/dev/null || true

	info "injected glibc $GLIBC_VER into lib/"
}

# move every executable into .bin/, hardlink sharun into bin/ and leave a
# symlink at the original path so the existing layout keeps working
_route() {
	while IFS='	' read -r _p _cls _mach _type _interp _runpath _needed _glibc; do
		_rel=${_p#"$APPDIR"/}
		# a musl program asks for the musl loader, the bundled glibc one
		# cannot run it and it does not need glibc in the first place
		case $_interp in *ld-musl*)
			info "left $_rel alone, it is a musl program"
			continue ;;
		esac
		_name=${_p##*/}
		# sharun gives a program called AppRun the meaning "start the app"
		[ "$_name" = AppRun ] && _name=AppRun.bin
		if [ -e "$APPDIR/.bin/$_name" ]; then
			_i=1
			while [ -e "$APPDIR/.bin/$_name.$_i" ]; do _i=$((_i + 1)); done
			_name=$_name.$_i
		fi

		mv "$_p" "$APPDIR/.bin/$_name"
		if [ "$_name" = "${_p##*/}" ]; then
			# sharun in place: /proc/self/exe keeps the path the program
			# had in the original AppImage, only its content changes
			ln -f "$APPDIR/sharun" "$_p"
		else
			# a program called AppRun, or one whose name is already taken
			mkdir -p "$APPDIR/bin"
			ln -f "$APPDIR/sharun" "$APPDIR/bin/$_name"
			ln -s "$(realpath -m --relative-to="$(dirname "$_p")" \
				"$APPDIR/bin/$_name")" "$_p"
		fi
		info "routed $_rel -> .bin/$_name"
	done < "$WORK/execs"
}

# AppRun becomes sharun, and sharun starts AppRun.sh. It runs it with /bin/sh
# and never looks at the shebang (find_shell() in apprun.rs), while the AppRun
# of a linuxdeploy AppImage is bash and uses `source`. So the original script
# keeps its own interpreter: it is preserved as AppRun.orig and AppRun.sh is a
# shim that execs it, which hands the shebang back to the kernel
_fix_apprun() {
	_ar=$APPDIR/AppRun
	[ -e "$_ar" ] || die "no AppRun in the AppDir"

	if [ -L "$_ar" ]; then
		# a symlink to the program, start what it pointed at
		_t=$(readlink "$_ar")
		case $_t in /*) _t=${_t#"$APPDIR"/} ;; esac
	elif [ "$_ar" -ef "$APPDIR/sharun" ]; then
		# an ELF AppRun, _route moved the real one to .bin/AppRun.bin
		_t=.bin/AppRun.bin
	else
		mv "$_ar" "$APPDIR/AppRun.orig"
		# the script may export LD_LIBRARY_PATH to the lib dirs of the
		# AppImage, and one of them now holds the bundled glibc. Left in
		# place, every helper it runs (grep, head, readlink, ...) would be
		# forced onto a foreign libc; sharun passes the library path to the
		# program itself, so the export is dropped
		if grep -q 'LD_LIBRARY_PATH=' "$APPDIR/AppRun.orig"; then
			sed -i -e '/^[[:space:]]*\(export[[:space:]]*\)*LD_LIBRARY_PATH=/d' \
				"$APPDIR/AppRun.orig"
			info "dropped LD_LIBRARY_PATH from AppRun.orig, lib.path covers it"
		fi
		_t=AppRun.orig
		info "AppRun script kept as AppRun.orig"
	fi

	{
		printf '#!/bin/sh\n'
		printf 'exec "$(dirname "$0")/%s" "$@"\n' "$_t"
	} > "$APPDIR/AppRun.sh"
	chmod +x "$APPDIR/AppRun.sh"
	rm -f "$_ar"
	cp "$SHARUN" "$APPDIR/AppRun"
	chmod +x "$APPDIR/AppRun"
	info "AppRun.sh starts $_t"
}

_lib_path() {
	"$APPDIR/sharun" -g 2>/dev/null || true
	_lp=$APPDIR/lib/lib.path
	[ -f "$_lp" ] || : > "$_lp"
	# sharun -g writes no trailing newline, our own entries would glue to it
	[ -s "$_lp" ] && [ -n "$(tail -c 1 "$_lp")" ] && printf '\n' >> "$_lp"
	# every directory of the AppImage that holds shared objects, they have to
	# be found before the ones of the host
	find "$APPDIR" -path "$APPDIR/lib" -prune -o -type d -print | while read -r _d; do
		set -- "$_d"/*.so*
		[ -e "$1" ] || continue
		printf '+/..%s\n' "${_d#"$APPDIR"}"
	done | sort -u > "$WORK/libdirs"
	grep -Fvxf "$_lp" "$WORK/libdirs" >> "$_lp" || true
	grep -qx '+' "$_lp" || sed -i '1i +' "$_lp"
	info "lib.path: $(tr '\n' ' ' < "$_lp")"
}

_pack() {
	[ -n "$MKSQUASHFS" ] || die "mksquashfs not found, set MKSQUASHFS"
	"$MKSQUASHFS" "$APPDIR" "$WORK/fs.squashfs" -noappend -all-root -no-progress \
		-comp "$COMP" -b "$BSIZE" >/dev/null || die "mksquashfs failed"
	cat "$WORK/runtime" "$WORK/fs.squashfs" > "$OUT"
	chmod +x "$OUT"
	info "wrote $OUT ($(du -h "$OUT" | cut -f1))"
}

_smoke() {
	_bin=$APPDIR/$1
	[ -x "$_bin" ] || die "$1: not executable"
	# SHARUN_DIR is what AppRun exports for the whole process tree, without
	# it a program that is started on its own cannot find the AppDir
	SHARUN_DIR=$APPDIR LD_DEBUG=libs "$_bin" >/dev/null 2>"$WORK/smoke.log" || true
	_libc=$(sed -n 's/.*calling init: \(.*libc\.so\.6\)$/\1/p' "$WORK/smoke.log" \
		| sort -u)
	[ -n "$_libc" ] || die "no libc.so.6 was loaded, see the log in $WORK"
	printf '%s\n' "$_libc" | while read -r _l; do info "libc.so.6 <- $_l"; done
	case $_libc in
	"$APPDIR"*) info "smoke test passed, libc comes from the AppDir" ;;
	*) die "smoke test FAILED, libc came from the host" ;;
	esac
}

GLIBC=${SHARUN_GLIBC:-}
OUT=
INPUT=
FORCE=0
KEEP=0
SMOKE=
while [ $# -gt 0 ]; do
	case $1 in
	-g) GLIBC=${2:?}; shift 2 ;;
	-o) OUT=${2:?}; shift 2 ;;
	-f) FORCE=1; shift ;;
	-k) KEEP=1; shift ;;
	--smoke) SMOKE=${2:?}; shift 2 ;;
	-h|--help) usage ;;
	-*) die "unknown option $1" ;;
	*)
		[ -z "$INPUT" ] || usage
		INPUT=$1
		shift ;;
	esac
done
[ -n "$INPUT" ] || usage

[ -x "$SHARUN" ] || die "sharun not found, put it next to this script or set SHARUN"
[ -n "$UNSQUASHFS" ] || die "unsquashfs not found, set UNSQUASHFS"

[ -n "$GLIBC" ] || die "no glibc payload given, use -g GLIBC_DIR"
[ -f "$GLIBC/libc.so.6" ] || die "$GLIBC: not a glibc payload dir"

WORK=$(mktemp -d)
if [ "$KEEP" = 1 ]; then
	trap 'rm -f "$WORK"/runtime "$WORK"/fs.squashfs; rmdir "$WORK" 2>/dev/null || true' EXIT
else
	trap 'rm -rf "$WORK"' EXIT
fi

if [ -d "$INPUT" ]; then
	APPDIR=$(cd "$INPUT" && pwd)
	COMP=gzip
	BSIZE=131072
	info "transforming $APPDIR in place"
else
	APPDIR=$WORK/AppDir
	[ -n "$OUT" ] || OUT=$(basename "${INPUT%.AppImage}")-glibc.AppImage
	_extract "$INPUT"
fi

GLIBC_VER=$(_glibc_version "$GLIBC")
CLASS=$(_elf_field "$(ls "$GLIBC"/ld-linux*.so* | head -n1)" 2)
info "glibc payload: $GLIBC_VER (${CLASS}-bit)"

# sharun starts every program with `ld.so --argv0`, an option the loader only
# learned in glibc 2.33; an older payload cannot be used at all
if _ver_lt "$GLIBC_VER" 2.33; then
	if [ "$FORCE" = 1 ]; then
		warn "glibc $GLIBC_VER predates --argv0, sharun needs 2.33 or newer"
	else
		die "glibc $GLIBC_VER predates --argv0, sharun needs 2.33 or newer (-f forces)"
	fi
fi

_inventory
if _ver_lt "$GLIBC_VER" "$MAXNEED"; then
	if [ "$FORCE" = 1 ]; then
		warn "glibc $GLIBC_VER is older than the required GLIBC_$MAXNEED"
	else
		die "glibc $GLIBC_VER is older than GLIBC_$MAXNEED, refusing (-f forces)"
	fi
fi

# the host libraries are the ones that make an old payload fail, and they fail
# on the machine that built the AppImage as well, so this one is worth a stop
_host_need
if _ver_lt "$GLIBC_VER" "$HOSTNEED"; then
	_who=$(awk -F'\t' -v v="$HOSTNEED" '$8 == v {print $1; exit}' \
		"$WORK/hostinfo")
	if [ "$FORCE" = 1 ]; then
		warn "glibc $GLIBC_VER cannot load $_who, it wants GLIBC_$HOSTNEED"
	else
		die "glibc $GLIBC_VER is older than GLIBC_$HOSTNEED, which $_who
from the host needs, so the AppImage would not start here (-f forces)"
	fi
fi

mkdir -p "$APPDIR/.bin"
cp "$SHARUN" "$APPDIR/sharun"
_inject_glibc
_route
_fix_apprun
_lib_path

[ -f "$WORK/runtime" ] && _pack
[ -n "$SMOKE" ] && _smoke "$SMOKE"

exit 0
