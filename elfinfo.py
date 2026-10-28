#!/usr/bin/env python3
"""Print one tab separated line per ELF file given on the command line.

    path class machine type interp runpath needed glibc

class is 32/64, machine is the EM_* name, type is EXEC/DYN/other, interp is
PT_INTERP, runpath is DT_RUNPATH/DT_RPATH, needed is a comma separated list of
DT_NEEDED and glibc is the highest GLIBC_x.y version the file requires. A file
that is not an ELF is reported with a class of "-", so the caller can filter it
out with a single rule.
"""

import struct
import sys

EM = {3: "i386", 62: "x86_64", 183: "aarch64", 20: "ppc", 21: "ppc64",
      22: "s390", 40: "arm", 243: "riscv"}
ET = {1: "REL", 2: "EXEC", 3: "DYN", 4: "CORE"}
PT_LOAD, PT_DYNAMIC, PT_INTERP = 1, 2, 3
DT_NULL, DT_NEEDED, DT_STRTAB, DT_RPATH, DT_RUNPATH = 0, 1, 5, 15, 29
DT_VERNEED, DT_VERNEEDNUM = 0x6FFFFFFE, 0x6FFFFFFF

# version names that are not a plain GLIBC_x.y
EXTRA = {"GLIBC_ABI_DT_RELR": (2, 36), "GLIBC_PRIVATE": None}


def fail(msg):
    print("elfinfo: %s" % msg, file=sys.stderr)


def parse(path):
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as err:
        fail("%s: %s" % (path, err))
        return None
    if len(data) < 52 or data[:4] != b"\x7fELF":
        return None

    cls, endian = data[4], data[5]
    if cls not in (1, 2) or endian not in (1, 2):
        return None
    e = "<" if endian == 1 else ">"
    is64 = cls == 2
    try:
        if is64:
            (e_type, e_machine, _, _, e_phoff, _, _, _, e_phentsize,
             e_phnum, _, _, _) = struct.unpack_from(e + "HHIQQQIHHHHHH", data, 16)
            ph_fmt = e + "IIQQQQQQ"
        else:
            (e_type, e_machine, _, _, e_phoff, _, _, _, e_phentsize,
             e_phnum, _, _, _) = struct.unpack_from(e + "HHIIIIIHHHHHH", data, 16)
            ph_fmt = e + "IIIIIIII"
        ph_size = struct.calcsize(ph_fmt)
        if e_phentsize != ph_size:
            return None

        segs, interp, dynamic = [], None, None
        for i in range(e_phnum):
            ph = struct.unpack_from(ph_fmt, data, e_phoff + i * ph_size)
            p_type = ph[0]
            if is64:
                p_offset, p_vaddr, p_filesz = ph[2], ph[3], ph[5]
            else:
                p_offset, p_vaddr, p_filesz = ph[1], ph[2], ph[4]
            if p_type == PT_LOAD:
                segs.append((p_vaddr, p_filesz, p_offset))
            elif p_type == PT_DYNAMIC:
                dynamic = (p_offset, p_filesz)
            elif p_type == PT_INTERP:
                raw = data[p_offset:p_offset + p_filesz]
                interp = raw.split(b"\x00")[0].decode("utf-8", "replace")

        out = {"class": "64" if is64 else "32",
               "machine": EM.get(e_machine, str(e_machine)),
               "type": ET.get(e_type, str(e_type)),
               "interp": interp or "", "runpath": "", "needed": [],
               "glibc": ()}
        if not dynamic:
            return out

        def v2o(addr):
            for vaddr, filesz, offset in segs:
                if vaddr <= addr < vaddr + filesz:
                    return offset + (addr - vaddr)
            return None

        dyn_fmt = e + ("qQ" if is64 else "iI")
        dyn_size = struct.calcsize(dyn_fmt)
        strtab = verneed = None
        runpath_off = None
        verneednum = 0
        needed_offs = []
        for i in range(dynamic[1] // dyn_size):
            tag, val = struct.unpack_from(dyn_fmt, data, dynamic[0] + i * dyn_size)
            if tag == DT_NULL:
                break
            if tag == DT_NEEDED:
                needed_offs.append(val)
            elif tag == DT_STRTAB:
                strtab = v2o(val)
            elif tag == DT_RUNPATH and runpath_off is None:
                out["runpath"] = "RUNPATH"
                runpath_off = val
            elif tag == DT_RPATH and runpath_off is None:
                out["runpath"] = "RPATH"
                runpath_off = val
            elif tag == DT_VERNEED:
                verneed = v2o(val)
            elif tag == DT_VERNEEDNUM:
                verneednum = val
        if strtab is None:
            return out

        def cstr(off):
            end = data.index(b"\x00", off)
            return data[off:end].decode("utf-8", "replace")

        out["needed"] = [cstr(strtab + o) for o in needed_offs]
        if runpath_off is not None:
            out["runpath"] += "=" + cstr(strtab + runpath_off)
        if verneed is None:
            return out

        best = ()
        vn_fmt = e + "HHIII"
        va_fmt = e + "IHHII"
        vn_off = verneed
        for _ in range(verneednum):
            _, vn_cnt, _, vn_aux, vn_next = struct.unpack_from(vn_fmt, data, vn_off)
            va_off = vn_off + vn_aux
            for _ in range(vn_cnt):
                _, _, _, vna_name, vna_next = struct.unpack_from(va_fmt, data, va_off)
                name = cstr(strtab + vna_name)
                ver = EXTRA.get(name, ())
                if not ver and name.startswith("GLIBC_"):
                    try:
                        ver = tuple(int(x) for x in name[6:].split(".")[:2])
                    except ValueError:
                        ver = ()
                if ver and ver > best:
                    best = ver
                va_off += vna_next
            vn_off += vn_next
        out["glibc"] = best
        return out
    except (struct.error, ValueError, IndexError) as err:
        fail("%s: malformed ELF: %s" % (path, err))
        return None


def main(paths):
    for path in paths:
        info = parse(path)
        if info is None:
            print("%s\t-\t-\t-\t-\t-\t-\t-" % path)
            continue
        print("%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s" % (
            path, info["class"], info["machine"], info["type"],
            info["interp"] or "-", info["runpath"] or "-",
            ",".join(info["needed"]) or "-",
            "%d.%d" % info["glibc"] if info["glibc"] else "-"))


if __name__ == "__main__":
    main(sys.argv[1:])
