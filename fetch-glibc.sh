#!/bin/sh
# fetch-glibc.sh - download a glibc payload for resharun.sh
#
# usage: fetch-glibc.sh [-d BASE] [VERSION]
#
#   VERSION  a glibc release such as 2.41, or nothing for the newest one in
#            the Arch repository. Older releases come from the Arch Linux
#            Archive, so 2.36 and 2.41 are still available.
#   -d BASE  unpack into BASE/glibc-<version> instead of ./glibc-<version>
#
# The path to use as `resharun.sh -g` is printed on stdout, the rest goes to
# stderr. The newest release is the safest choice: a payload older than the
# glibc the host libraries were built against cannot load them, while a newer
# one only asks for a newer kernel, and glibc 2.44 wants 4.4 (the value of
# --enable-kernel in the Arch package), which is from 2016.

set -eu

MIRROR=${MIRROR:-https://geo.mirror.pkgbuild.com}
ARCHIVE=${ARCHIVE:-https://archive.archlinux.org/packages/g/glibc}
PKG=glibc

die() { printf 'fetch-glibc: %s\n' "$*" >&2; exit 1; }
info() { printf '* %s\n' "$*" >&2; }

DIR=
while [ $# -gt 0 ]; do
	case $1 in
	-d) DIR=${2:?}; shift 2 ;;
	-h|--help) sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0" >&2; exit 0 ;;
	-*) die "unknown option $1" ;;
	*) break ;;
	esac
done
VER=${1:-}
[ $# -le 1 ] || die "too many arguments"

if command -v curl >/dev/null 2>&1; then
	_get() { curl -fsSL "$1"; }
	_download() { curl -fsSL -o "$2" "$1"; }
elif command -v wget >/dev/null 2>&1; then
	_get() { wget -qO- "$1"; }
	_download() { wget -qO "$2" "$1"; }
else
	die "neither curl nor wget found"
fi

if [ -n "$VER" ]; then
	_url=$ARCHIVE/
	info "looking for glibc $VER in the Arch Linux Archive"
else
	_url=$MIRROR/core/os/x86_64/
fi

# the listing has both glibc-2.44+r50+... and glibc-2.44%2Br50+... in it,
# and glibc-locales-* next to them
_file=$(_get "$_url" | grep -o "$PKG-[0-9][^\"<>]*x86_64\.pkg\.tar\.zst" |
	sed 's/%2B/+/g' | sort -uV)
[ -n "$_file" ] || die "nothing found at $_url"
if [ -n "$VER" ]; then
	_re=$(printf '%s' "$VER" | sed 's/\./\\./g')
	_file=$(printf '%s\n' "$_file" |
		grep -E "^$PKG-$_re([+-]|$)" || true)
	[ -n "$_file" ] || die "glibc $VER is not in the archive"
fi
_file=$(printf '%s\n' "$_file" | tail -n1)
# a literal + in a path is a space in a URL, the mirror expects %2B
_enc=$(printf '%s' "$_file" | sed 's/+/%2B/g')

_ver=$(printf '%s\n' "$_file" | sed "s/^$PKG-//; s/-[0-9]*-x86_64.*//")
DIR=${DIR:-.}/$PKG-$_ver

if [ -f "$DIR/usr/lib/libc.so.6" ]; then
	info "$DIR already holds glibc $_ver"
	printf '%s\n' "$DIR/usr/lib"
	exit 0
fi

info "downloading $_file"
_download "$_url$_enc" "$DIR.pkg.tar.zst.part" ||
	die "download of $_url$_enc failed"
mv "$DIR.pkg.tar.zst.part" "$DIR.pkg.tar.zst"

mkdir -p "$DIR"
# GNU tar needs --zstd for anything older than 1.35, busybox tar cannot do it
# at all, so fall back to zstd itself
if ! tar -xf "$DIR.pkg.tar.zst" -C "$DIR" 2>/dev/null; then
	tar --zstd -xf "$DIR.pkg.tar.zst" -C "$DIR" 2>/dev/null ||
		zstd -dc "$DIR.pkg.tar.zst" | tar -xf - -C "$DIR" ||
		die "cannot unpack $DIR.pkg.tar.zst"
fi
rm -f "$DIR.pkg.tar.zst"

[ -f "$DIR/usr/lib/libc.so.6" ] || die "$DIR: no usr/lib/libc.so.6 in the package"
info "glibc $_ver in $DIR/usr/lib"
printf '%s\n' "$DIR/usr/lib"
