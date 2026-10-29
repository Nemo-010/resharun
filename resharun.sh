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
# usage: resharun.sh [-f] [-k] [-b] [-o OUT.AppImage] [-g GLIBC_DIR]
#                    [--hostlibs host|repo] [--smoke BIN] APPIMAGE|APPDIR
#
#   -g GLIBC_DIR  glibc payload to inject, the usr/lib of an Arch glibc
#                 package. Without it the newest one is downloaded once and
#                 kept in the cache. Env: SHARUN_GLIBC
#   -o OUT        output AppImage (default: <name>-glibc.AppImage)
#   -f            go on even if the payload is older than what the binaries
#                 of the AppImage, or the libraries it takes from the host,
#                 require
#   -k            keep the unpacked AppDir for inspection
#   -b            also bring in the libraries the AppImage leaves to the host,
#                 which is what a musl distribution such as Alpine needs: there
#                 they are musl objects and the bundled glibc cannot load them
#   --hostlibs host|repo
#                 where -b takes them from. host copies them out of this
#                 machine, repo downloads them from the packages of the
#                 distribution the payload came from. Default: host when this
#                 machine has glibc, repo when it does not. Env: HOSTLIBS
#   --smoke BIN   after building, run BIN (path inside the AppDir) with
#                 LD_DEBUG=libs and report where libc.so.6 came from
#
# sharun is taken from SHARUN, from next to this script, or from PATH, and
# downloaded from Anylinux-sharun otherwise. Downloads are cached in
# ${XDG_CACHE_HOME:-~/.cache}/resharun, RESHARUN_CACHE moves that.

set -eu

PROG=${0##*/}
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
SHARUN=${SHARUN:-}
UNSQUASHFS=${UNSQUASHFS:-$(command -v unsquashfs || true)}
MKSQUASHFS=${MKSQUASHFS:-$(command -v mksquashfs || true)}

# what gets downloaded when it is not there, the way quick-sharun does it: a
# pinned release, checked against a known sha256
SHARUN_VERSION=${SHARUN_VERSION:-3.8.0}
SHARUN_BASE=${SHARUN_BASE:-https://github.com/pkgforge-dev/Anylinux-sharun/releases/download/$SHARUN_VERSION}
CACHE=${RESHARUN_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/resharun}

case $(uname -m) in
x86_64|amd64)
	ARCH=x86_64
	SHARUN_SHA=ed8eb105f29a90a5cdb919b9e0792829842cc264a1758fcb6d12fe5d16aa362b ;;
aarch64|arm64)
	ARCH=aarch64
	SHARUN_SHA=d9f45c07a3a154014407a023be50e0b0714bc452ba09a87e1e438d30058aa812 ;;
riscv64)
	ARCH=riscv64
	SHARUN_SHA=760995ddaf6e33eb74c8cc3d3b58ad5ed1923d2c73f6bd15479d281dc3ebdba0 ;;
loongarch64)
	ARCH=loongarch64
	SHARUN_SHA=ef61d2cc96df4d3c050dab48034594b013779141df89355daf4e6faf0e03ff39 ;;
ppc64)
	ARCH=ppc64
	SHARUN_SHA=9f172689a17128f65408d8deb21ae589b58ed6f2b1943316fdc90920242ac725 ;;
ppc64le)
	ARCH=ppc64le
	SHARUN_SHA=cedc66b45fd58f5c10981095305cce6a2438997265b83a0d1e78786258d37e2d ;;
*)
	ARCH=
	SHARUN_SHA= ;;
esac

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
info() { printf '* %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

usage() {
	sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0" >&2
	exit 1
}

_download() { # $1 url, $2 file
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL -o "$2" "$1"
	elif command -v wget >/dev/null 2>&1; then
		wget -qO "$2" "$1"
	else
		return 1
	fi
}

# sharun, from SHARUN, from next to this script, from PATH, or from the cache
# of downloads, in that order
_ensure_sharun() {
	[ -n "$SHARUN" ] || {
		if [ -x "$SELF_DIR/sharun" ]; then
			SHARUN=$SELF_DIR/sharun
		elif _p=$(command -v sharun 2>/dev/null); then
			SHARUN=$_p
		fi
	}
	[ -n "$SHARUN" ] && [ -x "$SHARUN" ] && return 0

	[ -n "$ARCH" ] || die "no sharun build for $(uname -m), put one next to this script"
	_c=$CACHE/sharun-$SHARUN_VERSION-$ARCH
	if [ ! -x "$_c" ]; then
		info "downloading sharun $SHARUN_VERSION for $ARCH"
		mkdir -p "$CACHE"
		_download "$SHARUN_BASE/sharun-$ARCH" "$_c.part" ||
			die "cannot download sharun, put one next to this script or set SHARUN"
		_sha=$(sha256sum "$_c.part" | cut -d' ' -f1)
		if [ "$_sha" != "$SHARUN_SHA" ]; then
			rm -f "$_c.part"
			die "the downloaded sharun has the wrong sha256: $_sha"
		fi
		chmod +x "$_c.part"
		mv "$_c.part" "$_c"
	fi
	SHARUN=$_c
}

# a glibc payload from fetch-glibc.sh, which takes the newest one in the Arch
# repository unless a version is asked for
_ensure_glibc() {
	[ -n "$GLIBC" ] && return 0
	[ -x "$SELF_DIR/fetch-glibc.sh" ] ||
		die "no payload given and no fetch-glibc.sh next to this script, use -g GLIBC_DIR"
	GLIBC=$("$SELF_DIR/fetch-glibc.sh" -d "$CACHE") || die "cannot fetch a glibc payload"
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
# here to avoid, so measure it instead of guessing. Only a glibc host can
# answer: elsewhere ldd resolves the names to musl objects, and the libraries
# that get bundled are checked instead, once they are there
_host_need() {
	HOSTNEED=0
	[ "$HOSTLIBS" = host ] || return 0
	_libdirs=$(_appdir_libdirs)
	while IFS='	' read -r _p _cls _mach _type _interp _runpath _needed _glibc; do
		[ "$_interp" = "-" ] && continue
		LD_LIBRARY_PATH=${_libdirs%:} ldd "$_p" 2>/dev/null |
			sed -n 's/.*=> \(\/[^ ]*\).*/\1/p'
	done < "$WORK/execs" | sort -u | grep -v "^$APPDIR/" |
		grep -v '/ld-linux\|/ld-musl\|/ld64' > "$WORK/hostlibs" || true
	[ -s "$WORK/hostlibs" ] || return 0
	# shellcheck disable=SC2046
	tr '\n' '\0' < "$WORK/hostlibs" |
		xargs -0 -r "$SELF_DIR/elfinfo.py" > "$WORK/hostinfo"
	HOSTNEED=$(awk -F'\t' '$8 != "-" {print $8}' "$WORK/hostinfo" |
		sort -Vu | tail -n1)
	[ -n "$HOSTNEED" ] || HOSTNEED=0
	info "host libraries need up to GLIBC_$HOSTNEED"
}

# the bundled libraries are the ones that run instead of the host ones, so the
# payload has to be new enough for them, whichever they came from
_bundle_need() {
	[ -d "$APPDIR/lib/hostlib" ] || return 0
	find "$APPDIR/lib/hostlib" -type f -name '*.so*' > "$WORK/bundled"
	[ -s "$WORK/bundled" ] || return 0
	# shellcheck disable=SC2046
	tr '\n' '\0' < "$WORK/bundled" |
		xargs -0 -r "$SELF_DIR/elfinfo.py" > "$WORK/bundleinfo"
	_bn=$(awk -F'\t' '$8 != "-" {print $8}' "$WORK/bundleinfo" |
		sort -Vu | tail -n1)
	[ -n "$_bn" ] || return 0
	if _ver_lt "$GLIBC_VER" "$_bn"; then
		_who=$(awk -F'\t' -v v="$_bn" '$8 == v {print $1; exit}' \
			"$WORK/bundleinfo")
		if [ "$FORCE" = 1 ]; then
			warn "glibc $GLIBC_VER cannot load $_who, it wants GLIBC_$_bn"
		else
			die "glibc $GLIBC_VER is older than GLIBC_$_bn, which $_who,
bundled from the repository, needs (-f forces)"
		fi
	fi
	info "bundled libraries need up to GLIBC_$_bn"
}

# the directories the bundled loader searches, in the order lib.path gives
# them: the payload first, then whatever was bundled beside it, then every
# directory of the AppImage that holds shared objects
_search_dirs() {
	printf '%s\n' "$APPDIR/lib"
	[ -d "$APPDIR/lib/hostlib" ] && printf '%s\n' "$APPDIR/lib/hostlib"
	printf '%s\n' "$(_appdir_libdirs)" | tr ':' '\n' | sed '/^$/d'
}

# what the AppDir does not carry, read out of DT_NEEDED instead of asked of
# the host: ldd on a musl system resolves the names to musl objects, and on
# any system it only knows what happens to be installed there. A program says
# what it needs in the file itself, so that is read, and the libraries it
# pulls in are followed the same way until nothing new turns up
_closure() { # $1 files to start from, $2 where to write the sonames
	_prov=$WORK/providers
	_search_dirs | while read -r _d; do
		for _f in "$_d"/*.so*; do
			[ -f "$_f" ] || continue
			printf '%s\t%s\n' "${_f##*/}" "$_f"
		done
	done | awk -F'\t' '!seen[$1]++' > "$_prov"

	: > "$WORK/seen"
	: > "$2"
	cp "$1" "$WORK/queue"
	while [ -s "$WORK/queue" ]; do
		tr '\n' '\0' < "$WORK/queue" |
			xargs -0 -r "$SELF_DIR/elfinfo.py" > "$WORK/round"
		awk -F'\t' '$7 != "-" {
			n = split($7, a, ",")
			for (i = 1; i <= n; i++) print a[i]
		}' "$WORK/round" | sort -u > "$WORK/need"
		awk -F'\t' 'NR == FNR { p[$1] = $2; next } !($1 in p)' \
			"$_prov" "$WORK/need" >> "$2"
		awk -F'\t' 'NR == FNR { p[$1] = $2; next } ($1 in p) { print p[$1] }' \
			"$_prov" "$WORK/need" | sort -u > "$WORK/found"
		sort -u "$WORK/seen" > "$WORK/seen.s"
		comm -23 "$WORK/found" "$WORK/seen.s" > "$WORK/queue"
		cat "$WORK/queue" >> "$WORK/seen.s"
		mv "$WORK/seen.s" "$WORK/seen"
	done
	sort -u -o "$2" "$2"
}

# the libraries an AppImage leaves to the host are what stops it from running
# where there is no glibc: on Alpine they are musl objects and the bundled
# loader cannot map them. Copy them in, with everything they need in turn,
# either out of the host when that is a glibc one, or out of the packages of
# the distribution the payload came from, which is what makes this work on a
# musl system and on one whose own libraries are too old for the application
_bundle_hostlibs() {
	[ "$BUNDLE" = 1 ] || return 0
	_dst=$APPDIR/lib/hostlib
	mkdir -p "$_dst"
	{ cat "$WORK/execs"; find "$_dst" -type f -name '*.so*' -print; } \
		> "$WORK/seed"
	_round=0
	_n=0
	while [ "$_round" -lt 10 ]; do
		_round=$((_round + 1))
		_closure "$WORK/seed" "$WORK/missing"
		[ -s "$WORK/missing" ] || break
		_before=$(find "$_dst" -type f | wc -l)
		case $HOSTLIBS in
		repo) _fetch_hostlibs "$WORK/missing" || break ;;
		*) _copy_hostlibs "$WORK/missing" || break ;;
		esac
		find "$_dst" -type f -name '*.so*' -print >> "$WORK/seed"
		_after=$(find "$_dst" -type f | wc -l)
		[ "$_after" -gt "$_before" ] || break
		_n=$_after
	done
	[ "$_n" -gt 0 ] && info "bundled $_n libraries the AppImage left to the host"
	return 0
}

# out of the host, which has to be a glibc one for the answer to be a glibc
# library: ldd resolves a name to a path only for a program that asks for it,
# so every program is asked at once and the answers are filtered by name
_copy_hostlibs() { # $1 sonames wanted
	_libdirs=$(_appdir_libdirs)$APPDIR/lib/hostlib
	while IFS='	' read -r _p _cls _mach _type _interp _runpath _needed _glibc; do
		[ "$_interp" = "-" ] && continue
		LD_LIBRARY_PATH=${_libdirs%:} ldd "$_p" 2>/dev/null |
			sed -n 's/.*=> \(\/[^ ]*\).*/\1/p'
	done < "$WORK/execs" | sort -u > "$WORK/hostpaths"
	awk -F'\t' 'NR == FNR { w[$1] = 1; next }
		{ n = split($0, q, "/"); if ((q[n] in w) && !(q[n] in got)) { got[q[n]] = 1; print } }' \
		"$1" "$WORK/hostpaths" > "$WORK/tocopy"
	while read -r _l; do
		[ -n "$_l" ] || continue
		cp "$_l" "$APPDIR/lib/hostlib/${_l##*/}" 2>/dev/null || true
	done < "$WORK/tocopy"
	return 0
}

# out of the repository, when the host has nothing to copy from
_fetch_hostlibs() { # $1 sonames wanted
	[ -x "$SELF_DIR/fetch-hostlibs.sh" ] ||
		die "no fetch-hostlibs.sh next to this script, and the host has no glibc
libraries to copy from"
	"$SELF_DIR/fetch-hostlibs.sh" -d "$APPDIR/lib/hostlib" < "$1" \
		> "$WORK/unfetched" || die "fetch-hostlibs.sh failed"
	if [ -s "$WORK/unfetched" ]; then
		warn "no package in the repository has these:"
		sed -n '1,12s/^/    /p' "$WORK/unfetched" >&2
	fi
	return 0
}

# the AppRun of a linuxdeploy AppImage is a bash script (`source`, mostly),
# and bash is not on a musl system by default, so an AppImage that is
# otherwise self-contained still cannot start there. The shell it asks for is
# fetched and routed like the programs are, and AppRun.sh starts the script
# with that one instead of the one the host has
_bundle_shell() { # $1 the AppRun script
	[ "$BUNDLE" = 1 ] || return 0
	_sb=$(sed -n '1s/^#![[:space:]]*//p' "$1")
	[ -n "$_sb" ] || return 0
	# shellcheck disable=SC2086
	set -- $_sb
	[ "${1##*/}" = env ] && shift
	[ $# -gt 0 ] || return 0
	_name=${1##*/}
	case $_name in
	sh|dash|ash|busybox|'')
		return 0 ;;
	esac
	# the host having it is not enough: the point of -b is that the result runs
	# where the host has nothing, and Alpine has no bash at all
	if [ -x "$APPDIR/usr/bin/$_name" ] || [ -x "$APPDIR/bin/$_name" ]; then
		SHELL_BIN=$_name
		return 0
	fi
	info "AppRun asks for $_name, fetching it so that the host need not have it"
	[ -x "$SELF_DIR/fetch-hostlibs.sh" ] ||
		die "no fetch-hostlibs.sh next to this script, cannot fetch $_name"
	printf 'bin/%s\n' "$_name" |
		"$SELF_DIR/fetch-hostlibs.sh" --bin-dir "$APPDIR/usr/bin" > "$WORK/shell" ||
		die "cannot fetch $_name"
	if [ -s "$WORK/shell" ]; then
		warn "no package in the repository has $_name, the AppRun keeps the one
of the host"
		return 0
	fi
	chmod +x "$APPDIR/usr/bin/$_name"
	SHELL_BIN=$_name
	printf '%s\n' "$APPDIR/usr/bin/$_name" >> "$WORK/execs"
	info "bundled $_name as the interpreter of AppRun"
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
		printf '%s\t%s\n' "$_rel" "$_name" >> "$WORK/routes"
		if [ "$_name" = "${_p##*/}" ]; then
			# sharun in place: /proc/self/exe keeps the path the program
			# had in the original AppImage, only its content changes
			ln -f "$APPDIR/sharun" "$_p"
		else
			# a program called AppRun, or one whose name is already taken.
			# The link has to be relative, the AppDir is mounted somewhere
			# else at run time, and realpath --relative-to is GNU only
			mkdir -p "$APPDIR/bin"
			ln -f "$APPDIR/sharun" "$APPDIR/bin/$_name"
			_up=
			_d=${_p#"$APPDIR"/}
			while [ "${_d#*/}" != "$_d" ]; do
				_up=$_up../
				_d=${_d#*/}
			done
			ln -s "${_up}bin/$_name" "$_p"
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
		if [ -n "$SHELL_BIN" ]; then
			printf 'exec "$(dirname "$0")/usr/bin/%s" "$(dirname "$0")/%s" "$@"\n' \
				"$SHELL_BIN" "$_t"
		else
			printf 'exec "$(dirname "$0")/%s" "$@"\n' "$_t"
		fi
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
	# sharun -g writes the entries of the payload. If it wrote nothing the file
	# is empty, and an empty pattern file means "no pattern" to busybox grep,
	# which then drops every entry added below: the AppImage would be packed
	# with an empty lib.path and load every library from the host
	[ -s "$_lp" ] || printf '+\n' > "$_lp"
	# sharun -g writes no trailing newline, our own entries would glue to it
	[ -n "$(tail -c 1 "$_lp")" ] && printf '\n' >> "$_lp"
	# every directory of the AppImage that holds shared objects, they have to
	# be found before the ones of the host
	find "$APPDIR" -path "$APPDIR/lib" -prune -o -name '*.so*' -print |
		while read -r _f; do
			_d=${_f%/*}
			[ "$_d" = "$APPDIR" ] || printf '+/..%s\n' "${_d#"$APPDIR"}"
		done | sort -u > "$WORK/libdirs"
	# the libraries copied out of the host, if -b was used. Entries are
	# relative to the lib directory, the way sharun -g writes them
	[ -d "$APPDIR/lib/hostlib" ] && printf '+/hostlib\n' >> "$WORK/libdirs"
	grep -Fvxf "$_lp" "$WORK/libdirs" >> "$_lp" || true
	# nothing of the AppDir in lib.path, but the AppDir does carry libraries:
	# the AppImage would start and take them from the host, which is the
	# failure this tool exists to prevent, so stop here instead
	if ! grep -q '^+/' "$_lp" &&
		find "$APPDIR" -path "$APPDIR/lib" -prune -o -name '*.so*' -print |
		grep -q .; then
		die "the AppDir has shared objects but none of them reached lib.path,
the AppImage would load all of them from the host"
	fi
	info "lib.path: $(tr '\n' ' ' < "$_lp")"
}

# what the bundled loader would not find at run time, so that the first run of
# the AppImage is not the one that has to report it. Whatever is not in the
# AppDir has to come from the host, and the payload loader only searches
# /lib and /usr/lib: never /usr/lib64, which is where Fedora and openSUSE keep
# theirs, and never anything at all on a musl system
_check_libs() {
	_ld=$(ls "$APPDIR"/lib/ld-linux*.so* 2>/dev/null | head -n1)
	[ -n "$_ld" ] || return 0
	# the bare "+" of lib.path is the lib directory of the AppDir itself
	_paths=$APPDIR/lib
	while read -r _e; do
		case $_e in
		+/*) _paths=$_paths:$APPDIR/lib/${_e#+/} ;;
		esac
	done < "$APPDIR/lib/lib.path"
	for _p in "$APPDIR"/.bin/*; do
		[ -f "$_p" ] || continue
		"$_ld" --library-path "$_paths" --list "$_p" 2>&1
	done > "$WORK/resolve" || true

	sed -n -e 's/^[[:space:]]*\([^ ]*\) => not found.*/\1/p' \
		-e 's/.*error while loading shared libraries: \([^:]*\):.*/\1/p' \
		"$WORK/resolve" | sort -u > "$WORK/missing"
	sed -n 's/^[[:space:]]*[^ ]* => \(\/[^ ]*\).*/\1/p' "$WORK/resolve" |
		grep -v "^$APPDIR/" | sort -u > "$WORK/outside"

	if [ -s "$WORK/missing" ]; then
		_n=$(wc -l < "$WORK/missing")
		warn "$_n libraries it needs are nowhere the bundled loader looks:"
		sed -n '1,12s/^/    /p' "$WORK/missing" >&2
		[ "$_n" -le 12 ] || printf '    ... and %s more\n' "$((_n - 12))" >&2
	fi
	if [ -s "$WORK/outside" ]; then
		_n=$(wc -l < "$WORK/outside")
		warn "$_n libraries still come from the host, it runs only where
they are, in /lib or /usr/lib:"
		sed -n '1,12s/^/    /p' "$WORK/outside" >&2
		[ "$_n" -le 12 ] || printf '    ... and %s more\n' "$((_n - 12))" >&2
		if [ "$BUNDLE" = 1 ]; then
			warn "they could not be copied in, see the messages above"
		else
			warn "-b copies them into the AppDir, which is what a musl
system such as Alpine needs"
		fi
	elif [ ! -s "$WORK/missing" ]; then
		info "self-contained: every library comes from the AppDir"
	fi
	return 0
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
	# the program has to be started the way the AppImage starts it, through the
	# hardlink to sharun that took its place: the file in .bin/ still has the
	# PT_INTERP of the host loader and would load the host libraries, which is
	# exactly what this test is supposed to catch
	_rel=$(awk -F'\t' -v n="${1##*/}" '$2 == n { print $1; exit }' \
		"$WORK/routes" 2>/dev/null)
	case $1 in
	.bin/*) _bin=$APPDIR/${_rel:-$1} ;;
	*) _bin=$APPDIR/$1 ;;
	esac
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
BUNDLE=0
SMOKE=
# where -b takes the libraries from: the host when it has glibc, which needs no
# download and gives the exact ones the AppImage was built against, and the
# packages of the payload distribution otherwise, which is the only option on a
# musl system and the right one on a distribution older than the AppImage
HOSTLIBS=${HOSTLIBS:-}
while [ $# -gt 0 ]; do
	case $1 in
	-g) GLIBC=${2:?}; shift 2 ;;
	-o) OUT=${2:?}; shift 2 ;;
	-f) FORCE=1; shift ;;
	-k) KEEP=1; shift ;;
	-b) BUNDLE=1; shift ;;
	--hostlibs) HOSTLIBS=${2:?}; shift 2 ;;
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

if [ -z "$HOSTLIBS" ]; then
	if ldd --version 2>/dev/null | grep -qi 'GNU libc'; then
		HOSTLIBS=host
	else
		HOSTLIBS=repo
	fi
fi
case $HOSTLIBS in
host|repo) ;;
*) die "--hostlibs takes host or repo, not '$HOSTLIBS'" ;;
esac

[ -n "$UNSQUASHFS" ] || die "unsquashfs not found, set UNSQUASHFS"
_ensure_sharun
_ensure_glibc
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

SHELL_BIN=

mkdir -p "$APPDIR/.bin"
: > "$WORK/routes"
cp "$SHARUN" "$APPDIR/sharun"
_inject_glibc
# before the routing: a shell that has to be fetched is a program like the
# others, it goes through the same path
[ -f "$APPDIR/AppRun" ] && _bundle_shell "$APPDIR/AppRun"
_bundle_hostlibs
_bundle_need
_route
_fix_apprun
_lib_path
_check_libs
[ -f "$WORK/runtime" ] && _pack
[ -n "$SMOKE" ] && _smoke "$SMOKE"

exit 0
