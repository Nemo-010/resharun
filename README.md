# resharun

Give an existing type-2 (squashfs) AppImage a glibc of its own, so that it
stops using the glibc of the host and uses the one carried inside the
AppDir instead.

This is the arrangement [quick-sharun] produces, applied after the fact to
an AppImage that was built the normal way, with appimagetool and a shell
script AppRun.

[quick-sharun]: https://github.com/pkgforge-dev/Anylinux-AppImages

## How it works

The dynamic loader of a program is chosen by its `PT_INTERP`, which is an
absolute path such as `/lib64/ld-linux-x86-64.so.2`, so it cannot simply be
pointed at a file inside an AppDir whose mount point is only known at
runtime. [sharun] sidesteps that: it maps the loader it wants into the
process itself with `userland-execve` and jumps to it, passing
`--library-path`. No `execve` happens, so the `PT_INTERP` of the program is
never consulted.

`resharun.sh` puts that mechanism around the programs of an existing
AppImage. For every executable in the AppDir it:

1. moves the real program to `.bin/<name>`,
2. replaces the path it had with a hardlink to `sharun` (or a symlink into
   `bin/` when the name is already taken, or is `AppRun`),

so the program re-enters sharun when it is executed, keeps its own path for
`argv[0]` and `/proc/self/exe`, and is then started by the bundled loader.
`AppRun` becomes sharun and the AppRun script of the AppImage becomes
`AppRun.orig`, which a small `AppRun.sh` shim execs: sharun runs `AppRun.sh`
with `/bin/sh` and never looks at its shebang, and the AppRun of a
linuxdeploy AppImage is bash (`source`), so the script has to keep the
interpreter it asked for.

The bundled loader is patched so that `/etc` becomes `/KEK`, which keeps it
away from the `/etc/ld.so.cache` and `/etc/ld.so.preload` of the host. The
host cache would otherwise resolve sonames to host libraries, which defeats
the whole exercise.

## Requirements

* `python3` for `elfinfo.py`
* `unsquashfs` and `mksquashfs` (4.6 or newer) in `PATH`, or via the
  `UNSQUASHFS` / `MKSQUASHFS` environment variables
* `zstd`, only to unpack the Arch package the payload comes from: busybox tar
  cannot read `.pkg.tar.zst` and GNU tar older than 1.35 needs it too
* `ldd` from the glibc of the host, which is how the requirement of the host
  libraries is measured
* `curl` or `wget`, only to download what is not there yet

On a musl distribution such as Alpine, `apk add python3 squashfs-tools zstd`
covers it, and `elfinfo.py` has to sit next to the scripts. There is no glibc
`ldd` there, so the measurement of the host libraries comes out empty and its
check is skipped, which is harmless: a host without glibc has no glibc
libraries for the payload to be incompatible with.

`sharun` and the glibc payload are downloaded when they are missing, so
nothing has to be fetched by hand. Downloads go to
`${XDG_CACHE_HOME:-~/.cache}/resharun` and are reused; `RESHARUN_CACHE`,
`SHARUN` and `-g` override them, which is what you want after the first run
or on a machine without a network.

## Usage

```sh
./resharun.sh app.AppImage
```

That is the whole thing: sharun is fetched from
[Anylinux-sharun](https://github.com/pkgforge-dev/Anylinux-sharun) (pinned
release, checked against a known sha256, the way quick-sharun does it), the
newest glibc payload is fetched from the Arch repository, the AppImage is
rewritten as `app-glibc.AppImage`, and both stay in the cache.

Options: `-o` output file, `-g` a payload you already have, `-f` ignore the
version gates, `-k` keep the unpacked AppDir, `--smoke BIN` run `BIN` with
`LD_DEBUG=libs` after the build and report which `libc.so.6` was loaded.

Pinning a glibc release, or unpacking one elsewhere:

```sh
./fetch-glibc.sh                 # newest, prints the path to use with -g
./fetch-glibc.sh 2.41            # a specific release
./fetch-glibc.sh -d /tmp/glibcs  # into /tmp/glibcs/glibc-<version>

./resharun.sh -g glibc-2.41/usr/lib app.AppImage
```

## Which glibc

The payload is not a matter of taste, and the newest one is the safe one. A
glibc stays compatible with programs that were built against an older one,
so a payload that is too new breaks nothing but the kernel it needs, while
one that is too old cannot load the libraries of the host, and those are the
ones an AppImage leans on: X11, mesa, the GPU driver, fontconfig, the
desktop toolkits, everything it did not bundle itself.

`resharun.sh` measures it. It resolves the libraries every program would
load, and takes the highest `GLIBC_x.y` among those that live outside the
AppDir. Rewriting the AppImageLauncher AppImage on an Artix host of glibc
2.44, one payload at a time:

| payload | AppImage needs | host libraries need | result |
| --- | --- | --- | --- |
| 2.33 | 2.34 | | `ail-cli` cannot start |
| 2.36 | 2.34 | 2.38 (`libX11`, `libGLX`, `libfreetype`) | cannot start |
| 2.39 | 2.34 | 2.42 (`libgpg-error`) | cannot start |
| 2.41 | 2.34 | 2.42 | cannot start |
| 2.44 | 2.34 | 2.42 | runs |

So the floor is `max(2.33, what the AppImage needs, what the host needs)`.
The last term moves with the glibc of the machine the AppImage runs on, and
no payload can be chosen in advance to match it, which is why the newest
payload is the one that lasts longest and why there is no version worth
pinning: anything a release or two behind the host is enough, because the
libraries of the host were built before it.

The kernel is the only thing a payload can be too new for:

* the Arch package is built with `--enable-kernel=4.4`, so a payload taken
  from Arch wants Linux 4.4 or newer, which is from 2016
* a Debian or Ubuntu payload is built with `--enable-kernel=3.2`
  (`MIN_KERNEL_SUPPORTED := 3.2` in `debian/sysdeps/linux.mk`), so it is the
  one to use if kernels older than 4.4 still matter
* glibc 2.33 is a hard floor either way, sharun starts every program with
  `ld.so --argv0` and the loader only learned that option in 2.33

## What ends up in the AppDir

```
AppRun            copy of sharun
AppRun.sh         shim that execs AppRun.orig
AppRun.orig       the AppRun script of the original AppImage
sharun
lib/              the glibc payload, gconv, and lib.path
.bin/<name>       the real programs
bin/<name>        only for programs whose name was taken or is AppRun
usr/bin/<name>    hardlink to sharun, was the program
```

`lib/lib.path` lists the library directories, `+` being `lib/` itself and
`+/../usr/lib` the library directory the AppImage already had, so the
bundled glibc is found before the libraries of the host and the libraries
of the AppImage are found before the ones of the host.

## Gates

* the payload must not be older than the highest `GLIBC_x.y` any ELF of the
  AppImage requires, otherwise the programs cannot start
* the payload must not be older than the highest `GLIBC_x.y` among the host
  libraries the AppImage loads, which is measured with `ldd` and is what
  breaks first in practice
* the payload must be 2.33 or newer, because of `--argv0`
* an AppImage that already carries a libc is refused, it does not need this
* an AppImage with no dynamic executable is refused, a bundled glibc would
  change nothing

## Limits

* `ldd` is only as good as the host it runs on: a library that only exists
  on the machines of some of the users cannot be measured, only guessed at
* quick-sharun handles `dlopen` of libraries built for another libc with
  `cross-libc-dlopen`, this script does not bundle it
* the AppRun shim hands the original script back to its own interpreter, so
  a bash AppRun still needs bash on the host, exactly as before
* an AppRun that is a binary has to be started through `bin/AppRun.bin`,
  which is not the path it had, so a program that works out its prefix from
  `/proc/self/exe` would land one directory deeper than before; a script or
  a symlink AppRun keeps its path
* musl programs and executables of a different ELF class than the payload
  are left on their own loader
* the squashfs must be readable by `unsquashfs`; a DwarFS image is not
