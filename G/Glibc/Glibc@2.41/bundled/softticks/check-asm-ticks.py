#!/usr/bin/env python3
"""check-asm-ticks.py BUILDDIR EXPECTED: fails unless every object of a glibc build that was
assembled from assembly source has as many rr software ticks as EXPECTED says.

An object assembled from assembly is one without a .comment section (compilers write their
.ident there, GNU as does not for .S files) that has code (an executable section with bytes).
Its ticks are the occurrences of the ABI's x86-64 tick sequence (rr's include/rr/softticks.h,
version 1: testb $0x80, 0x70001807; jnz; decq 0x70001800; jnz; int3, 21 bytes) in its
executable sections.  EXPECTED has a line "COUNT PATH" per object (PATH relative to BUILDDIR);
the objects of the test suite (tst-*, test-*, bench-*, testroot.*) are left out.  Any object
missing, unexpected, or with another count fails the check, with a list of them."""
import os, struct, sys

TICK = bytes([0xf6, 0x04, 0x25, 0x07, 0x18, 0x00, 0x70, 0x80, 0x75, 0x0b,
              0x48, 0xff, 0x0c, 0x25, 0x00, 0x18, 0x00, 0x70, 0x75, 0x01, 0xcc])
SHF_EXECINSTR, SHT_PROGBITS = 4, 1


def sections(d):
    if d[:4] != b"\x7fELF" or d[4] != 2 or d[5] != 1:
        return None
    shoff, = struct.unpack_from("<Q", d, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", d, 0x3a)
    out = []
    for i in range(shnum):
        nm, typ, flags, _, off, size = struct.unpack_from("<IIQQQQ", d, shoff + i * shentsize)
        out.append([nm, typ, flags, off, size])
    so = out[shstrndx][3]
    for s in out:
        s[0] = d[so + s[0]:d.index(b"\0", so + s[0])].decode()
    return out


def assembled(build):
    found = {}
    for root, dirs, files in os.walk(build):
        dirs[:] = [x for x in dirs if not x.startswith("testroot.")]
        for f in files:
            if not f.endswith((".o", ".os", ".oS")) or f.startswith(("tst-", "test-", "bench-")):
                continue
            p = os.path.join(root, f)
            with open(p, "rb") as fh:
                d = fh.read()
            secs = sections(d)
            if secs is None or any(s[0] == ".comment" and s[4] for s in secs):
                continue
            code = [s for s in secs if s[2] & SHF_EXECINSTR and s[1] == SHT_PROGBITS and s[4]]
            if code:
                found[os.path.relpath(p, build)] = sum(d[s[3]:s[3] + s[4]].count(TICK)
                                                       for s in code)
    return found


def main():
    build, expected = sys.argv[1:3]
    want = {}
    for line in open(expected):
        line = line.split("#", 1)[0].split()
        if line:
            want[line[1]] = int(line[0])
    got = assembled(build)
    bad = []
    for p in sorted(set(want) | set(got)):
        if p not in got:
            bad.append("%s: not built (expected %d ticks)" % (p, want[p]))
        elif p not in want:
            bad.append("%s: %d ticks, not in %s" % (p, got[p], os.path.basename(expected)))
        elif got[p] != want[p]:
            bad.append("%s: %d ticks, expected %d" % (p, got[p], want[p]))
    total = sum(got.values())
    if bad:
        sys.stderr.write("rr software ticks: %d objects assembled from assembly do not tick as "
                         "expected:\n  %s\n" % (len(bad), "\n  ".join(bad)))
        sys.exit(1)
    print("rr software ticks: %d objects assembled from assembly, %d ticks, as expected"
          % (len(got), total))


if __name__ == "__main__":
    main()
