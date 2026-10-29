#!/bin/sh
# fetch-hostlibs.sh - fetch the shared libraries an AppImage leaves to the
# host out of a package repository, so that they can be bundled on a machine
# that has no glibc libraries to copy them from, or whose own are too old for
# the application.
#
# usage: fetch-hostlibs.sh [-a ARCH] [-d DEST] [--bin-dir DIR] < sonames
#
# The sonames come on stdin, one per line. Each one is looked up in an index
# of the repository, the package that ships it is downloaded and checked
# against its sha256, and the library is copied into DEST under the name of
# the soname. Sonames that could not be provided are printed on stdout, one
# per line, so the caller can decide what to do about them.
#
# A line of the form bin/NAME asks for a program instead of a library, which
# is how the shell an AppRun asks for is bundled; it goes to --bin-dir.
#
# The index maps a soname to the package that ships it. It is downloaded when
# HOSTLIBS_INDEX_URL has one (a few hundred kilobytes), and built here
# otherwise: that costs one 51MB download, is streamed rather than unpacked,
# and is kept for HOSTLIBS_INDEX_TTL days. Packages are Arch ones, the same
# distribution the glibc payload comes from, so the libraries are built
# against the payload rather than against whatever glibc the machine running
# this happens to have.
#
#   HOSTLIBS_MIRROR     mirror the packages come from
#   HOSTLIBS_INDEX_URL  prebuilt index, empty to always build it
#   HOSTLIBS_INDEX_TTL  days a built index is kept, default 30
#   RESHARUN_CACHE      where downloads and the index are kept

set -eu

PROG=${0##*/}
CACHE=${RESHARUN_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/resharun}
MIRROR=${HOSTLIBS_MIRROR:-https://geo.mirror.pkgbuild.com}
INDEX_URL=${HOSTLIBS_INDEX_URL-https://github.com/Nemo-010/resharun/releases/latest/download/hostlibs}
INDEX_TTL=${HOSTLIBS_INDEX_TTL:-30}
DEST=.
BINDIR=

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
info() { printf '* %s\n' "$*" >&2; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

case $(uname -m) in
x86_64|amd64) ARCH=x86_64 ;;
aarch64|arm64) ARrch64 ;;
riscv64) ARCH=riscv64 ;;
loongarch64) ARCH=loongarch64 ;;
ppc64) ARCH=ppc64 ;;
ppc64le) ARCH=ppc64le ;;
*) ARCH= ;;
esac

while [ $# -gt 0 ]; do
	case $1 in
	-a) ARCH=${2:?}; shift 2 ;;
	-d) DEST=${2:?}; shift 2 ;;
	--bin-dir) BINDIR=${2:?}; shift 2 ;;
	-h|--help) sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0" >&2; exit 1 ;;
	*) die "unknown option $1" ;;
	esac
done
[ -n "$ARCH" ] || die "no repository for $(uname -m), use -a"
mkdir -p "$DEST"

_sha256() { sha256sum "$1" | cut -d' ' -f1; }

_download() { # $1 url, $2 file
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL -o "$2" "$1"
	elif command -v wget >/dev/null 2>&1; then
		wget -qO "$2" "$1"
	else
		die "neither curl nor wget is here"
	fi
}

# tar reads .pkg.tar.zst only when it was built with zstd, and busybox tar
# never does, so zstd is always in the pipeline. Only usr/lib is taken out of
# the package: a package that ships a library among its own files can be
# hundreds of megabytes, and none of the rest of it is of any use here
_untar_zst() { # $1 archive, $2 dir
	# a package has one of the two, rarely both, and tar treats the one that
	# is not there as an error even though it unpacked the other
	zstd -dc "$1" | tar -xf - -C "$2" usr/lib usr/bin 2>/dev/null || true
	[ -d "$2" ]
}

# one line per soname of the repository: the package that ships it, the file
# name to fetch and its sha256. The file list of a distribution is a tar of
# one desc and one files member per package, and unpacking it costs 600MB, so
# it is streamed instead: a member that starts with %FILENAME% is a desc, one
# that starts with %FILES% is the list of the package the desc before it
# described
_build_index() { # $1 output file
	_tmp=$CACHE/index-build
	rm -rf "$_tmp"
	mkdir -p "$_tmp"
	: > "$_tmp/raw"
	case $ARCH in i?86) _bits=32 ;; *) _bits=64 ;; esac
	for _db in core extra; do
		info "downloading the file list of $_db"
		_download "$MIRROR/$_db/os/$ARCH/$_db.files.tar.gz" "$_tmp/$_db.tar.gz" ||
			die "cannot download $_db.files.tar.gz"
		tar -xzOf "$_tmp/$_db.tar.gz" |
			awk -v repo="$_db" -v bits="$_bits" '
				/^%FILENAME%$/ { k = "file"; next }
				/^%SHA256SUM%$/ { k = "sha"; next }
				/^%ISIZE%$/ { k = "size"; next }
				/^%PROVIDES%$/ { k = "prov"; next }
				/^%FILES%$/ { k = "files"; next }
				/^%/ { k = ""; next }
				k == "file" { fn = $0; k = ""; next }
				k == "sha" { sha[fn] = $0; k = ""; next }
				k == "size" { isize[fn] = $0; k = ""; next }
				# libz.so=1-64 says the package is the one that provides the
				# soname libz.so.1, which is the answer the loader wants
				k == "prov" && /^.+[.]so=[0-9.]+-[0-9]+$/ {
					p = index($0, ".so=")
					base = substr($0, 1, p - 1)
					r = substr($0, p + 4)
					a = r; sub(/.*-/, "", a)
					v = r; sub(/-[0-9]+$/, "", v)
					if (a == bits) provs[fn] = provs[fn] base ".so." v "\n"
					next
				}
				k == "files" && /^usr\/bin\// {
					n = split($0, q, "/"); f = q[n]
					bins[fn] = bins[fn] "bin/" f "\t" f "\n"
				}
				k == "files" && /^usr\/lib\// {
					n = split($0, q, "/"); f = q[n]
					if (f !~ /\.so(\.[0-9][^/]*)?$/) next
					b = f; sub(/\.so.*/, "", b)
					libs[fn]++
					files[fn] = files[fn] f "\t" b "\n"
				}
				END {
					for (p in provs) {
						n = split(provs[p], l, "\n")
						for (i = 1; i <= n; i++)
							if (l[i] != "")
								printf "%s\t%s\t%s\t%s\t%s\t0\t-\t0\n", \
									l[i], repo, p, sha[p], isize[p]
					}
					for (p in files) {
						n = split(files[p], l, "\n")
						for (i = 1; i <= n; i++) {
							if (l[i] == "") continue
							split(l[i], c, "\t")
							printf "%s\t%s\t%s\t%s\t%s\t1\t%s\t%d\n", \
								c[1], repo, p, sha[p], isize[p], c[2], libs[p]
						}
					}
					# a program, so that a shell the AppRun asks for can be
					# bundled as well: keyed as bin/<name>
					for (p in bins) {
						n = split(bins[p], l, "\n")
						for (i = 1; i <= n; i++) {
							if (l[i] == "") continue
							split(l[i], c, "\t")
							printf "%s\t%s\t%s\t%s\t%s\t1\t%s\t0\n", \
								c[1], repo, p, sha[p], isize[p], c[2]
						}
					}
				}' >> "$_tmp/raw"
		rm -f "$_tmp/$_db.tar.gz"
	done
	[ "$(wc -l < "$_tmp/raw")" -gt 1000 ] ||
		die "the file list came out short, the download was probably cut off"

	# several packages can carry the same soname, and one of them is usually
	# an application that bundles a copy (julia has a libstdc++, nsight has
	# one too). A package that provides the soname is the answer, and where
	# none does: the one named after the library, then the one in core, then
	# the one that is a library package rather than an application that
	# happens to ship one, and never a package so big that unpacking it is a
	# problem
	awk -F'\t' '{
		split($3, v, "-")
		score = ($6 == 0 ? 0 : 10000) \
			+ (tolower($7) == tolower(v[1]) ? 0 : 1000) \
			+ ($2 == "core" ? 0 : 100) \
			+ ($5 > 300000000 ? 500 : 0) \
			- ($8 > 20 ? 20 : $8)
		if (!($1 in best) || score < best[$1]) {
			best[$1] = score
			line[$1] = $1 "\t" $2 "\t" $3 "\t" $4
		}
	} END { for (s in line) print line[s] }' "$_tmp/raw" | sort > "$1"
	rm -rf "$_tmp"
	[ -s "$1" ] || die "the index came out empty"
}

_fresh() { # $1 file, $2 days
	[ -s "$1" ] || return 1
	_now=$(date +%s)
	_then=$(date -r "$1" +%s 2>/dev/null || echo 0)
	[ $((_now - _then)) -lt $(($2 * 86400)) ]
}

_ensure_index() {
	_index=$CACHE/hostlibs-$ARCH.tsv
	_fresh "$_index" "$INDEX_TTL" && return 0
	mkdir -p "$CACHE"
	if [ -n "$INDEX_URL" ]; then
		if _download "$INDEX_URL-$ARCH.tsv.gz" "$_index.part" 2>/dev/null; then
			if gunzip -c "$_index.part" > "$_index.tmp" 2>/dev/null &&
				[ -s "$_index.tmp" ]; then
				mv "$_index.tmp" "$_index"
				rm -f "$_index.part"
				return 0
			fi
		fi
		rm -f "$_index.part" "$_index.tmp"
		info "no prebuilt index, building one from the mirror"
	fi
	_build_index "$_index.tmp"
	mv "$_index.tmp" "$_index"
}

# a package is kept under its own name and unpacked once, several sonames
# commonly come out of the same one
_fetch_pkg() { # $1 repo, $2 filename, $3 sha256
	_dir=$CACHE/pkgs
	mkdir -p "$_dir"
	_pkg=$_dir/$2
	if [ -f "$_pkg" ] && [ "$(_sha256 "$_pkg")" = "$3" ]; then
		return 0
	fi
	_download "$MIRROR/$1/os/$ARCH/$2" "$_pkg.part" || return 1
	_sha=$(_sha256 "$_pkg.part")
	if [ "$_sha" != "$3" ]; then
		rm -f "$_pkg.part"
		warn "$2 has the wrong sha256, expected $3 and got $_sha"
		return 2
	fi
	mv "$_pkg.part" "$_pkg"
}

_ensure_index

_work=$(mktemp -d)
trap 'rm -rf "$_work"' EXIT

tr -d '\r' | sed -n '/^[^	 ][^	 ]*$/p' | sort -u > "$CACHE/want"
[ -s "$CACHE/want" ] || exit 0

# the packages the wanted sonames come out of
awk -F'\t' 'NR == FNR { want[$1] = 1; next } ($1 in want)' \
	"$CACHE/want" "$CACHE/hostlibs-$ARCH.tsv" > "$CACHE/hits"
if [ ! -s "$CACHE/hits" ]; then
	cat "$CACHE/want"
	exit 0
fi
cut -f2,3,4 "$CACHE/hits" | sort -u > "$CACHE/pkgs.want"

while IFS='	' read -r _repo _file _sha; do
	[ -n "$_file" ] || continue
	_fetch_pkg "$_repo" "$_file" "$_sha" || die "cannot fetch $_file"
done < "$CACHE/pkgs.want"

# unpack each of them once and take out what was asked for
: > "$CACHE/got"
while IFS='	' read -r _key _repo _file _sha; do
	[ -n "$_key" ] || continue
	case $_key in
	bin/*) _name=${_key#bin/}; _sub=usr/bin ;;
	*) _name=$_key; _sub=usr/lib ;;
	esac
	_x=$_work/$_file
	if [ ! -d "$_x" ]; then
		rm -rf "$_x"
		mkdir -p "$_x"
		_untar_zst "$CACHE/pkgs/$_file" "$_x" || die "cannot unpack $_file"
	fi
		# a library is usually a symlink to its versioned file, and a package
		# can also ship a directory of that name (usr/lib/bash/), so anything
		# that is not a directory will do
		_l=$(find "$_x/$_sub" -maxdepth 1 ! -type d -name "$_name" 2>/dev/null | head -n1)
		[ -n "$_l" ] || _l=$(find "$_x" ! -type d -name "$_name" 2>/dev/null | head -n1)
	if [ -z "$_l" ]; then
		warn "$_file does not carry $_key"
		continue
	fi
	case $_key in
	bin/*)
		[ -n "$BINDIR" ] || die "$_key is a program, use --bin-dir"
		mkdir -p "$BINDIR"
		cp "$_l" "$BINDIR/$_name"
		chmod +x "$BINDIR/$_name"
		;;
	# a symlink is copied as the file it points at: a second name for the
	# same library is of no use in the AppDir
	*) cp "$_l" "$DEST/$_key" ;;
	esac
	printf '%s\n' "$_key" >> "$CACHE/got"
done < "$CACHE/hits"

# what is still missing goes back to the caller on stdout
sort -u "$CACHE/got" > "$CACHE/got.u"
comm -23 "$CACHE/want" "$CACHE/got.u"
exit 0
