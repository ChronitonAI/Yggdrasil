#!/usr/bin/env python3
"""Place rr software ticks in GMP's x86-64 assembly.

  gmpticks.py plan SRCDIR BUILDDIR PLAN.json   choose a tick for every loop
  gmpticks.py apply PLAN.json SRCDIR DESTDIR   insert the chosen ticks into a source tree

The tracee ABI (rr's include/rr/softticks.h, version 1) wants no instrumented (pc, sp) to
repeat without a tick in between: a tick at every function entry (PROLOGUE does that, see
the RR_SOFTTICK macros in mpn/x86_64/x86_64-defs.m4 that rr-softticks-1-macros.patch adds)
and on every cycle of the code.  This finds the cycles of the code as the build assembles
it and chooses, for each, where a tick goes in the m4 source and which form it takes.  A
tick clobbers the arithmetic flags, and GMP's carry chains (adc/sbb with dec/inc/lea/jrcxz
counters; adcx/adox) keep CF, or CF and OF, live around many loops: a tick goes where no
flag is live if the loop has such a place on every iteration, and otherwise keeps CF (or
CF and OF) in the low byte of a register that is dead there.

plan: SRCDIR is the source tree (the recipe's patches and rr-softticks-1-macros.patch
applied) and BUILDDIR an x86-64 build directory configured from it (--enable-fat, so that
every CPU's code is there, with a compiler that does not predefine __RR_SOFTTICKS__, so
that the RR_SOFTTICK macros expand to nothing) with its mpn/*.asm units (configure makes
them; nothing needs to be built).  Every unit is expanded by m4 as the build does it (from
a twin of the sources whose lines carry a comment marker that survives m4, checked to
expand to the same code), assembled with gas, and read back with llvm-objdump: the
instructions, the CFG (jump tables and computed jumps resolved, with the over-approximation
the binary tick check makes for them, so that its view of the code has no unticked cycle
either), the liveness of the flags and of the general registers, and for each instruction
the source line before which a tick would go.  Then ticks are chosen in rounds: each round
gives every strongly connected component that still has a cycle without a tick one tick,
for the header (target of an address-order back edge) with the largest region (the nodes
on cycles through its back edges), on the forced path from that header within the region
(every such cycle runs it), at a source line valid in every unit that expands it: cheapest
first (RR_SOFTTICK where no flag is live; RR_SOFTTICK_CF or RR_SOFTTICK_CO with dead
registers), then outside the reach of jrcxz/loop (8-bit displacements only), then
earliest.  The chosen positions are cut from the graphs and the next round looks at what
is left, so an inner loop whose exit leads round an outer loop (which already ticks) gets a
place past its exit test.

apply: writes the macros into the .asm files: on a line of their own before the chosen
line, or after the label(s) that start it.  Needs Python 3.7+, m4, gcc (GNU as) and
llvm-objdump ($GMPTICKS_OBJDUMP, default llvm-objdump)."""
import bisect, json, os, re, shutil, subprocess, sys
from collections import Counter, defaultdict
from multiprocessing import Pool

OBJDUMP = os.environ.get("GMPTICKS_OBJDUMP", "llvm-objdump")
M4 = os.environ.get("GMPTICKS_M4", "m4")


def run(cmd, cwd=None):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("%s failed: %s" % (" ".join(cmd), r.stderr[-2000:]))
    return r.stdout


# =============================================================================== x86-64
# What an instruction (llvm-objdump's AT&T syntax) reads and writes of the arithmetic
# flags and the general registers.  As the binary tick check models the flags: a flag an
# instruction leaves undefined counts as written; a shift or rotate by %cl writes none (the
# count may be 0); calls clobber them.  A write of an 8- or 16-bit register keeps the rest,
# so it reads the register too.  An unknown instruction reads everything and writes
# nothing (the safe direction for liveness).

FLAGS = "CPAZSO"
ALLF = frozenset(FLAGS)

GPR = ["rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp",
       "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"]
ALLR = frozenset(GPR)
CALLEE_SAVED = frozenset(["rbx", "rbp", "r12", "r13", "r14", "r15", "rsp"])
ARGS = frozenset(["rdi", "rsi", "rdx", "rcx", "r8", "r9", "rax", "rsp"])
CALLER_SAVED = frozenset(["rax", "rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "r11"])

REG = {}  # name -> (parent, width)
for i, (q, d, w, b) in enumerate([("rax", "eax", "ax", "al"), ("rbx", "ebx", "bx", "bl"),
                                  ("rcx", "ecx", "cx", "cl"), ("rdx", "edx", "dx", "dl"),
                                  ("rsi", "esi", "si", "sil"), ("rdi", "edi", "di", "dil"),
                                  ("rbp", "ebp", "bp", "bpl"), ("rsp", "esp", "sp", "spl")]):
    REG[q] = (q, 64); REG[d] = (q, 32); REG[w] = (q, 16); REG[b] = (q, 8)
for q, h in [("rax", "ah"), ("rbx", "bh"), ("rcx", "ch"), ("rdx", "dh")]:
    REG[h] = (q, 8)
for n in range(8, 16):
    q = "r%d" % n
    REG[q] = (q, 64); REG[q + "d"] = (q, 32); REG[q + "w"] = (q, 16); REG[q + "b"] = (q, 8)
REG["rip"] = (None, 64)

CC = {"o": "O", "no": "O", "b": "C", "c": "C", "nae": "C", "ae": "C", "nb": "C", "nc": "C",
      "e": "Z", "z": "Z", "ne": "Z", "nz": "Z", "be": "CZ", "na": "CZ", "a": "CZ", "nbe": "CZ",
      "s": "S", "ns": "S", "p": "P", "pe": "P", "np": "P", "po": "P", "l": "SO", "nge": "SO",
      "ge": "SO", "nl": "SO", "le": "ZSO", "ng": "ZSO", "g": "ZSO", "nle": "ZSO"}
CCR = "|".join(sorted(CC, key=len, reverse=True))


def split_ops(s):
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur.strip()); cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


REGTOK = re.compile(r"%([a-z0-9]+)")


class Op:
    def __init__(self, text):
        self.text = text
        t = text.lstrip("*")
        self.indirect = text.startswith("*")
        self.imm = t.startswith("$")
        self.mem = "(" in t or (not t.startswith("%") and not self.imm)
        self.reg = None
        self.width = None
        self.addr_regs = set()
        if not self.imm and not self.mem:
            name = t[1:]
            if name in REG:
                self.reg, self.width = REG[name]
            elif name.startswith(("xmm", "ymm", "zmm", "mm", "st")):
                self.reg = None  # vector / x87: not tracked
                self.width = "vec"
            else:
                self.reg = None
        elif self.mem:
            for r in REGTOK.findall(t):
                if r in REG and REG[r][0]:
                    self.addr_regs.add(REG[r][0])

    @property
    def is_gpr(self):
        return self.reg is not None


def eff(mn, opstr):
    """-> dict(fr, fw, rr, rw, kind) ; kind: 'seq', 'jmp', 'jcc', 'call', 'ret', 'ijmp', 'halt'."""
    ops = [Op(o) for o in split_ops(opstr)] if opstr else []
    fr, fw, rr, rw = set(), set(), set(), set()
    kind = "seq"
    for o in ops:
        rr |= o.addr_regs

    def src(o):
        if o.is_gpr:
            rr.add(o.reg)

    def dst(o, read=False):
        if o.is_gpr:
            if o.width in (8, 16) or read:
                rr.add(o.reg)
            rw.add(o.reg)

    m = mn
    # prefixes
    if m.split()[0] in ("rep", "repz", "repe", "repnz", "repne") and m.split()[1].startswith("ret"):
        return pack(fr, fw, {"rax", "rdx"} | CALLEE_SAVED, rw, "ret")
    if m.split()[0] in ("rep", "repz", "repe", "repnz", "repne"):
        # rep-prefixed string instructions; repe/repne cmps and scas write no flag (rcx may
        # be 0)
        rr |= {"rcx", "rsi", "rdi", "rax"}
        rw |= {"rcx", "rsi", "rdi"}
        return pack(fr, fw, rr, rw, kind)
    if m.startswith("lock "):
        m = m.split()[1]
    if re.fullmatch(r"(movs|stos|lods|cmps|scas)[bwlq]", m):
        # string instructions without rep: what they read, and the pointers they advance
        b = m[:4]
        rr |= {"movs": {"rsi", "rdi"}, "cmps": {"rsi", "rdi"}, "stos": {"rax", "rdi"},
               "scas": {"rax", "rdi"}, "lods": {"rsi"}}[b]
        rw |= {"movs": {"rsi", "rdi"}, "cmps": {"rsi", "rdi"}, "stos": {"rdi"},
               "scas": {"rdi"}, "lods": {"rsi", "rax"}}[b]
        if b in ("cmps", "scas"):
            fw |= ALLF
        return pack(fr, fw, rr, rw, kind)

    def base_of(m, bases):
        for b in bases:
            if m == b or (m[:-1] == b and m[-1] in "bwlq"):
                return b
        return None

    # control flow
    if m in ("jmp", "jmpq"):
        if ops and ops[0].indirect:
            kind = "ijmp"
            src_ops = ops[0]
            if src_ops.is_gpr:
                rr.add(src_ops.reg)
        else:
            kind = "jmp"
        return pack(fr, fw, rr, rw, kind)
    mm = re.fullmatch(r"j(%s)" % CCR, m)
    if mm:
        return pack(set(CC[mm.group(1)]), fw, rr, rw, "jcc")
    if m in ("jrcxz", "jecxz"):
        return pack(fr, fw, {"rcx"}, rw, "jcc")
    if m in ("loop", "loopq"):
        return pack(fr, fw, {"rcx"}, {"rcx"}, "jcc")
    if m in ("loope", "loopz", "loopne", "loopnz"):
        return pack({"Z"}, fw, {"rcx"}, {"rcx"}, "jcc")
    if m in ("call", "callq"):
        if ops and ops[0].indirect and ops[0].is_gpr:
            rr.add(ops[0].reg)
        rr |= ARGS
        return pack(fr, ALLF, rr, CALLER_SAVED, "call")
    if m in ("ret", "retq"):
        return pack(fr, fw, {"rax", "rdx"} | CALLEE_SAVED, rw, "ret")
    if m in ("ud2", "hlt", "int3"):
        return pack(fr, fw, rr, rw, "halt")

    b = base_of(m, ["nop"])
    if b or m in ("emms", "lfence", "sfence", "mfence", "pause", "cld", "endbr64"):
        return pack(set(), set(), set(), set(), "seq")

    # setcc / cmovcc
    mm = re.fullmatch(r"set(%s)" % CCR, m)
    if mm:
        fr |= set(CC[mm.group(1)])
        dst(ops[-1])
        return pack(fr, fw, rr, rw, kind)
    mm = re.fullmatch(r"cmov(%s)[wlq]?" % CCR, m)
    if mm:
        fr |= set(CC[mm.group(1)])
        src(ops[0]); dst(ops[1], read=True)
        return pack(fr, fw, rr, rw, kind)

    # ALU two-operand: dst = dst op src, all flags written
    b = base_of(m, ["add", "sub", "and", "or", "xor"])
    if b:
        if len(ops) == 2 and ops[0].is_gpr and ops[1].is_gpr and ops[0].reg == ops[1].reg \
                and b in ("xor", "sub") and ops[0].width in (32, 64):
            rw.add(ops[1].reg)  # zero idiom
        else:
            for o in ops[:-1]:
                src(o)
            dst(ops[-1], read=True)
        return pack(fr, ALLF, rr, rw, kind)
    b = base_of(m, ["adc", "sbb"])
    if b:
        if len(ops) == 2 and ops[0].is_gpr and ops[1].is_gpr and ops[0].reg == ops[1].reg \
                and b == "sbb" and ops[0].width in (32, 64):
            rw.add(ops[1].reg)  # -CF
        else:
            for o in ops[:-1]:
                src(o)
            dst(ops[-1], read=True)
        return pack({"C"}, ALLF, rr, rw, kind)
    b = base_of(m, ["adcx"])
    if b:
        src(ops[0]); dst(ops[1], read=True)
        return pack({"C"}, {"C"}, rr, rw, kind)
    b = base_of(m, ["adox"])
    if b:
        src(ops[0]); dst(ops[1], read=True)
        return pack({"O"}, {"O"}, rr, rw, kind)
    b = base_of(m, ["cmp", "test"])
    if b:
        for o in ops:
            src(o)
        return pack(fr, ALLF, rr, rw, kind)
    b = base_of(m, ["inc", "dec"])
    if b:
        dst(ops[0], read=True)
        return pack(fr, set("PAZSO"), rr, rw, kind)
    b = base_of(m, ["neg"])
    if b:
        dst(ops[0], read=True)
        return pack(fr, ALLF, rr, rw, kind)
    b = base_of(m, ["not", "bswap"])
    if b:
        dst(ops[0], read=True)
        return pack(fr, fw, rr, rw, kind)
    # shifts and rotates
    b = base_of(m, ["shl", "sal", "shr", "sar", "rol", "ror", "rcl", "rcr"])
    if b:
        if len(ops) == 1:
            cnt = "1"
            d = ops[0]
        else:
            cnt = ops[0].text
            d = ops[1]
        dst(d, read=True)
        by_cl = cnt == "%cl"
        if by_cl:
            rr.add("rcx")
        if b in ("rcl", "rcr"):
            fr.add("C")
            if not by_cl and not (d.width in (8, 16)):
                fw |= {"C", "O"}
        elif b in ("rol", "ror"):
            if not by_cl:
                fw |= {"C", "O"}
        else:
            if not by_cl:
                fw |= ALLF
        return pack(fr, fw, rr, rw, kind)
    b = base_of(m, ["shld", "shrd"])
    if b:
        cnt = ops[0].text if len(ops) == 3 else "%cl"
        if cnt == "%cl":
            rr.add("rcx")
        else:
            fw |= ALLF
        src(ops[-2]); dst(ops[-1], read=True)
        return pack(fr, fw, rr, rw, kind)
    b = base_of(m, ["shlx", "shrx", "sarx", "rorx", "bzhi", "pdep", "pext"])
    if b:
        for o in ops[:-1]:
            src(o)
        dst(ops[-1])
        if b == "bzhi":
            fw |= ALLF
        return pack(fr, fw, rr, rw, kind)
    b = base_of(m, ["andn"])
    if b:
        for o in ops[:-1]:
            src(o)
        dst(ops[-1])
        return pack(fr, ALLF, rr, rw, kind)
    b = base_of(m, ["mulx"])
    if b:
        # AT&T: mulx src, lo, hi ; implicit rdx
        src(ops[0]); rr.add("rdx")
        dst(ops[1]); dst(ops[2])
        return pack(fr, fw, rr, rw, kind)
    b = base_of(m, ["mul", "imul"])
    if b:
        if len(ops) == 1:
            src(ops[0]); rr.add("rax")
            rw |= {"rax", "rdx"}
            if ops[0].width in (8,):
                rw.discard("rdx")
        elif len(ops) == 2:
            src(ops[0]); dst(ops[1], read=True)
        else:
            src(ops[1]); dst(ops[2])
        return pack(fr, ALLF, rr, rw, kind)
    b = base_of(m, ["div", "idiv"])
    if b:
        src(ops[0]); rr |= {"rax", "rdx"}; rw |= {"rax", "rdx"}
        return pack(fr, ALLF, rr, rw, kind)
    b = base_of(m, ["bt"])
    if b:
        for o in ops:
            src(o)
        return pack(fr, set("CPASO"), rr, rw, kind)
    b = base_of(m, ["bts", "btr", "btc"])
    if b:
        src(ops[0]); dst(ops[1], read=True)
        return pack(fr, set("CPASO"), rr, rw, kind)
    b = base_of(m, ["bsf", "bsr", "lzcnt", "tzcnt", "popcnt"])
    if b:
        src(ops[0])
        # bsf/bsr leave the destination unchanged for a zero source
        dst(ops[1], read=b in ("bsf", "bsr"))
        return pack(fr, ALLF, rr, rw, kind)
    if m in ("clc", "stc"):
        return pack(fr, {"C"}, rr, rw, kind)
    if m == "cmc":
        return pack({"C"}, {"C"}, rr, rw, kind)
    if m == "lahf":
        return pack(set("SZAPC"), fw, {"rax"}, {"rax"}, kind)
    if m == "sahf":
        return pack(fr, set("SZAPC"), {"rax"}, rw, kind)
    if m in ("pushfq", "pushf"):
        return pack(ALLF, fw, {"rsp"}, {"rsp"}, kind)
    if m in ("popfq", "popf"):
        return pack(fr, ALLF, {"rsp"}, {"rsp"}, kind)
    b = base_of(m, ["push"])
    if b:
        src(ops[0]); rr.add("rsp"); rw.add("rsp")
        return pack(fr, fw, rr, rw, kind)
    b = base_of(m, ["pop"])
    if b:
        dst(ops[0]); rr.add("rsp"); rw.add("rsp")
        return pack(fr, fw, rr, rw, kind)
    b = base_of(m, ["xchg", "xadd", "cmpxchg"])
    if b:
        for o in ops:
            dst(o, read=True)
        if b != "xchg":
            fw |= ALLF
        if b == "cmpxchg":
            rr.add("rax"); rw.add("rax")
        return pack(fr, fw, rr, rw, kind)
    if m == "cpuid":
        return pack(fr, fw, {"rax", "rcx"}, {"rax", "rbx", "rcx", "rdx"}, kind)
    if m in ("cqto", "cqo"):
        return pack(fr, fw, {"rax"}, {"rdx"}, kind)
    if m in ("cltq", "cdqe"):
        return pack(fr, fw, {"rax"}, {"rax"}, kind)
    if m in ("cltd", "cdq"):
        return pack(fr, fw, {"rax"}, {"rdx"}, kind)
    b = base_of(m, ["lea"])
    if b:
        dst(ops[1])
        return pack(fr, fw, rr, rw, kind)
    # moves: mov, movzx/movsx forms, movq/movd between gpr and xmm, vector moves
    if re.fullmatch(r"mov[bwlq]?|movabsq|movz[bw][wlq]|movs[bw][wlq]|movslq|movsx[a-z]*|movzx[a-z]*", m):
        src(ops[0]); dst(ops[1])
        return pack(fr, fw, rr, rw, kind)
    if m in ("movd", "movq", "vmovd", "vmovq", "pextrq", "pextrd", "vpextrq", "pinsrq", "vpinsrq", "pinsrd"):
        for o in ops[:-1]:
            src(o)
        dst(ops[-1], read=m.startswith(("pinsr", "vpinsr")))
        return pack(fr, fw, rr, rw, kind)
    # SSE/AVX/MMX without flags or GPR destinations (operands only read address registers)
    if re.fullmatch(r"v?(p[a-z0-9]+|mov[a-z0-9]*|[a-z]+p[sd]|shufp[sd]|unpck[a-z]+|palignr)", m) and \
            not m.startswith(("ptest", "vptest", "pcmpestr", "pcmpistr", "pmovmsk", "vpmovmsk", "pextr", "vpextr", "popcnt")):
        for o in ops:
            if o.is_gpr:
                rr.add(o.reg)
        return pack(fr, fw, rr, rw, kind)
    if m.startswith(("pmovmsk", "vpmovmsk")):
        dst(ops[-1])
        return pack(fr, fw, rr, rw, kind)
    return None  # unknown


def pack(fr, fw, rr, rw, kind):
    rr = set(rr); rw = set(rw)
    rr.discard(None); rw.discard(None)
    return dict(fr=frozenset(fr), fw=frozenset(fw), rr=frozenset(rr), rw=frozenset(rw), kind=kind)


def unknown():
    return dict(fr=ALLF, fw=frozenset(), rr=ALLR, rw=frozenset(), kind="seq", unknown=True)

# =============================================================================== sources
# Markers: a gas comment `#@FILEID:LINE` appended to a source line (before a trailing `C`
# comment or `dnl`), so that the expanded output line that line produces carries it, also
# inside quoted blocks (ifdef bodies), where m4's synclines would only give the line the
# block started on.  A line that ends inside an unquoted macro argument list gets none (a
# comment there would become part of the argument).  The annotated expansion must equal the
# plain one with the markers removed (checked for every unit).

MARK = re.compile(r"#@(\d+):(\d+)")
MARK_ANY = re.compile(r"\s*#@\d+:\d+")

def find_comment_tok(line, start_q):
    """Scan one line with quote depth start_q at its start.  Returns (insert column or None
    when the line gets no marker, quote depth at EOL, paren delta at depth 0)."""
    q = start_q
    i, n = 0, len(line)
    pdelta = 0
    ins = None
    while i < n:
        c = line[i]
        if q == 0 and c == "#":
            ins = n  # an m4 comment: the marker goes at the end, inside it
            break
        if c == "`":
            q += 1
        elif c == "'" and q > 0:
            q -= 1
        elif q == 0 and c == "(":
            pdelta += 1
        elif q == 0 and c == ")":
            pdelta -= 1
        # GMP's C comment macro and dnl, as words (at any quote depth: they act on rescan)
        if (c == "C" or line.startswith("dnl", i)) and (i == 0 or not (line[i - 1].isalnum() or line[i - 1] in "_$.")):
            w = 1 if c == "C" else 3
            after = line[i + w:i + w + 1]
            if after == "" or after in " \t" or (w == 3 and not (after.isalnum() or after == "_")):
                if ins is None:
                    ins = i
                # the rest of the line is a comment (on rescan, for quoted text): stop counting
                # quotes only when unquoted; inside quotes keep scanning for the closing quote
                if q == 0:
                    break
        i += 1
    if ins is None:
        ins = n
    return ins, q, pdelta


def annotate_text(text, fid, exclude=()):
    lines = text.split("\n")
    out = []
    q = 0
    pdepth = 0
    marked = 0
    starts = {}
    for ln, line in enumerate(lines, 1):
        starts[ln] = (q, pdepth)
        ins, q_end, pdelta = find_comment_tok(line, q)
        ok = (q == 0 and pdepth == 0) or q > 0
        # the line must also not end inside an unquoted argument list
        if q_end == 0 and pdepth + pdelta > 0:
            ok = False
        if ln in exclude or line.strip() == "" or line.lstrip().startswith(("dnl", "C\t", "C ")) or line.strip() == "C":
            ok = False
        if ok:
            pre = line[:ins].rstrip()
            post = line[ins:]
            line = pre + " #@%d:%d" % (fid, ln) + ((" " + post) if post else "")
            marked += 1
        pdepth = max(0, pdepth + pdelta)
        q = q_end
        out.append(line)
    return "\n".join(out), marked, starts


def safe_start(st):
    """A line that starts at top level or inside quoted text: a new line can go before it."""
    q, p = st
    return (q == 0 and p == 0) or q > 0


def build_twin(srcroot, buildroot, twinroot):
    """The annotated twin of a configured build: TWIN/<src name>/mpn (every .asm under
    mpn/x86_64 annotated) and TWIN/<build name>/{config.m4, mpn/*.asm}, so that the relative
    paths config.m4 and the unit wrappers use resolve the same way."""
    srcroot, buildroot, twinroot = map(os.path.abspath, (srcroot, buildroot, twinroot))
    if os.path.dirname(srcroot) != os.path.dirname(buildroot):
        raise SystemExit("the source and build directories must be siblings")
    if os.path.exists(twinroot):
        shutil.rmtree(twinroot)
    tsrc = os.path.join(twinroot, os.path.basename(srcroot))
    shutil.copytree(os.path.join(srcroot, "mpn"), os.path.join(tsrc, "mpn"), symlinks=True)
    fids, starts = [], {}
    for d, _, fs in sorted(os.walk(os.path.join(tsrc, "mpn", "x86_64"))):
        for f in sorted(fs):
            if not f.endswith(".asm"):
                continue
            p = os.path.join(d, f)
            real = os.path.join(srcroot, os.path.relpath(p, tsrc))
            a, _, st = annotate_text(open(p).read(), len(fids))
            fids.append(real)
            with open(p, "w") as fh:
                fh.write(a)
            starts[real] = st
    tb = os.path.join(twinroot, os.path.basename(buildroot))
    os.makedirs(os.path.join(tb, "mpn"))
    shutil.copy(os.path.join(buildroot, "config.m4"), tb)
    for f in os.listdir(os.path.join(buildroot, "mpn")):
        if f.endswith(".asm"):
            sp, dp = os.path.join(buildroot, "mpn", f), os.path.join(tb, "mpn", f)
            if os.path.islink(sp):
                os.symlink(os.readlink(sp), dp)
            else:
                shutil.copy(sp, dp)
    return dict(fids=fids, starts=starts, mpn=os.path.join(tb, "mpn"))


def normalize(text):
    """The expansion without comments, markers and blank lines, whitespace collapsed."""
    out = []
    for ln in text.split("\n"):
        m = MARK_ANY.search(ln)
        if m:
            ln = ln[:m.start()]
        i = ln.find("#")
        if i >= 0:
            ln = ln[:i]
        ln = " ".join(ln.split())
        if ln:
            out.append(ln)
    return out


def m4_output(mpndir, unit):
    """A unit as mpn/Makeasm.am expands it (m4-ccas: the shared library's -DPIC)."""
    return run([M4, "-DHAVE_CONFIG_H", "-D__GMP_WITHIN_GMP", "-DOPERATION_" + unit[:-4], "-DPIC", unit],
               cwd=mpndir)


LABEL_RE = re.compile(r"^\s*([A-Za-z_.$][\w.$]*|\d+):")


def parse_marked(out, fids):
    """Labels and data directives of an expansion, with the source line of their output
    line's marker (None without one) and their section."""
    items = []
    section, stack = ".text", []
    for raw in out.split("\n"):
        m = MARK.search(raw)
        f, l = (fids[int(m.group(1))], int(m.group(2))) if m else (None, None)
        s = raw.split("#", 1)[0]
        for stmt in s.split(";"):
            while True:
                lm = LABEL_RE.match(stmt)
                if not lm:
                    break
                items.append(("label", lm.group(1), "", f, l, section))
                stmt = stmt[lm.end():]
            t = stmt.strip()
            if not t.startswith("."):
                continue
            p = t.split(None, 1)
            d, ops = p[0], (p[1].strip() if len(p) > 1 else "")
            if d == ".text":
                section = ".text"
            elif d in (".data", ".bss"):
                section = d
            elif d == ".section":
                section = ops.split(",")[0].strip()
            elif d == ".pushsection":
                stack.append(section); section = ops.split(",")[0].strip()
            elif d == ".popsection":
                section = stack.pop() if stack else ".text"
            items.append(("dir", d, ops, f, l, section))
    return items


def to_gas(out, fids):
    """The assembler input: a local label .Lrrln<N> before output line N, so that the
    symbol table gives every line's address (gas writes no line rows for the .byte-encoded
    instructions, mulx, adcx, adox), and each line's source from its marker."""
    res, src = [], {}
    for i, raw in enumerate(out.split("\n")):
        m = MARK.search(raw)
        if m:
            src[i] = (fids[int(m.group(1))], int(m.group(2)))
        res.append(".Lrrln%d:" % i)
        res.append(raw)
    return "\n".join(res) + "\n", src


def is_code(sec):
    return sec == ".text" or sec.startswith(".text")


# =============================================================================== objects

class Insn:
    __slots__ = ("sec", "addr", "size", "mn", "ops", "cmt", "reloc", "addend", "e", "succ",
                 "pred", "file", "line", "idx", "tailcall")

    def __init__(self, sec, addr, mn, ops, cmt):
        self.sec, self.addr, self.mn, self.ops, self.cmt = sec, addr, mn, ops, cmt
        self.reloc, self.addend = None, 0
        self.succ, self.pred = [], []
        self.file = self.line = None
        self.tailcall = False


class Unit:
    """One unit, assembled from its marked expansion and read back."""

    def __init__(self, mpndir, unit, work, out, fids):
        self.unit, self.out = unit, out
        self.items = parse_marked(out, fids)
        os.makedirs(work, exist_ok=True)
        s = os.path.join(work, unit[:-4] + ".s")
        o = os.path.join(work, unit[:-4] + ".o")
        gas, self.line_src = to_gas(out, fids)
        with open(s, "w") as f:
            f.write(gas)
        run(["gcc", "-c", "-Wa,-L", s, "-o", o], cwd=mpndir)
        self.obj = o
        self._symbols()
        self._disasm()
        self._lines()
        self._tables()
        self._cfg()

    def _symbols(self):
        self.sym, self.line_addr = {}, {}
        self.addr_labels = defaultdict(list)
        for ln in run([OBJDUMP, "-t", self.obj]).split("\n"):
            m = re.match(r"^([0-9a-f]{16}) (.{7}) (\S+)\t([0-9a-f]+) (.*)$", ln)
            if not m:
                continue
            addr, flags, sec, name = int(m.group(1), 16), m.group(2), m.group(3), m.group(5).strip()
            if sec in ("*UND*", "*ABS*") or flags[6] in "df":
                continue
            if name.startswith(".hidden "):
                name = name[8:]
            if name.startswith(".Lrrln"):
                self.line_addr[int(name[6:])] = (sec, addr)
                continue
            self.sym[name] = (sec, addr)
            self.addr_labels[(sec, addr)].append(name)

    def _disasm(self):
        self.insns = []
        sec = None
        for ln in run([OBJDUMP, "-d", "-r", "--no-show-raw-insn", self.obj]).split("\n"):
            m = re.match(r"^Disassembly of section (\S+):", ln)
            if m:
                sec = m.group(1); continue
            m = re.match(r"^\s+([0-9a-f]+):\s+(R_X86_64_\w+)\s+(\S+)", ln)
            if m and self.insns:
                a, tgt = int(m.group(1), 16), m.group(3)
                for ins in reversed(self.insns[-3:]):
                    if ins.sec == sec and ins.addr < a:
                        ins.reloc = (m.group(2), re.sub(r"[-+]0x[0-9a-f]+$", "", tgt))
                        am = re.search(r"([-+])0x([0-9a-f]+)$", tgt)
                        ins.addend = (int(am.group(2), 16) * (-1 if am.group(1) == "-" else 1)) if am else 0
                        break
                continue
            m = re.match(r"^\s+([0-9a-f]+):\s+(\S+)(?:\s+(.*))?$", ln)
            if m:
                mn, ops, cmt = m.group(2), (m.group(3) or "").strip(), None
                if "#" in ops:
                    ops, cmt = ops.split("#", 1)
                    ops = ops.strip()
                if mn in ("rep", "repz", "repe", "repne", "repnz", "lock", "notrack") and ops:
                    p = ops.split(None, 1)
                    mn, ops = mn + " " + p[0], (p[1] if len(p) > 1 else "")
                self.insns.append(Insn(sec, int(m.group(1), 16), mn, ops, cmt))
        size = {}
        for s in set(i.sec for i in self.insns):
            m = re.search(r"^\s*\d+\s+%s\s+([0-9a-f]+)" % re.escape(s), run([OBJDUMP, "-h", self.obj]), re.M)
            size[s] = int(m.group(1), 16)
        for i, ins in enumerate(self.insns):
            ins.idx = i
            nxt = self.insns[i + 1] if i + 1 < len(self.insns) else None
            ins.size = (nxt.addr if nxt is not None and nxt.sec == ins.sec else size[ins.sec]) - ins.addr
        self.at = {(i.sec, i.addr): i for i in self.insns}

    def _lines(self):
        """An instruction's source line is its output line's: the last output line (in text
        order) at the highest address not above the instruction's."""
        per = defaultdict(list)
        for i, (sec, a) in self.line_addr.items():
            per[sec].append((a, i))
        for v in per.values():
            v.sort()
        for ins in self.insns:
            lst = per.get(ins.sec)
            k = bisect.bisect_right(lst, (ins.addr, 1 << 60)) - 1 if lst else -1
            if k >= 0:
                src = self.line_src.get(lst[k][1])
                if src:
                    ins.file, ins.line = src

    def _tables(self):
        """Jump tables (a label in a data section followed by .long X-Y or .quad X entries)
        and the code addresses that a rip-relative lea puts in each register."""
        self.tables, cur = {}, None
        for kind, text, ops, _, _, section in self.items:
            if is_code(section):
                cur = None
            elif kind == "label":
                cur = text
                self.tables.setdefault(cur, [])
            elif text in (".long", ".quad", ".int") and cur is not None:
                for e in ops.split(","):
                    m = re.match(r"^([.A-Za-z_$][\w.$]*)(?:\s*-\s*[.A-Za-z_$][\w.$]*)?$", e.strip())
                    if m and m.group(1) in self.sym and self.sym[m.group(1)] in self.at:
                        self.tables[cur].append(self.sym[m.group(1)])
        self.tables = {k: v for k, v in self.tables.items() if v}
        self.data_label = {self.sym[k]: k for k in self.tables if k in self.sym}
        self.table_targets = set(t for v in self.tables.values() for t in v)
        self.code_lea = defaultdict(set)
        for ins in self.insns:
            if ins.mn.startswith("lea") and "(%rip)" in ins.ops and ins.cmt and ins.reloc is None:
                m = re.match(r"\s*0x([0-9a-f]+)", ins.cmt)
                dst = split_ops(ins.ops)[-1].lstrip("%")
                if m and (ins.sec, int(m.group(1), 16)) in self.at and dst in REG:
                    self.code_lea[REG[dst][0]].add((ins.sec, int(m.group(1), 16)))
                    self.table_targets.add((ins.sec, int(m.group(1), 16)))

    def _table_of(self, ins):
        if not (ins.mn.startswith("lea") and "(%rip)" in ins.ops and ins.reloc):
            return None
        name = ins.reloc[1]
        if name in self.tables:
            return name
        return self.data_label.get((name, ins.addend + 4)) if name.startswith(".") else None

    def _ijmp_targets(self, ins):
        """An indirect jump's targets: its table's entries (a lea of a table among the few
        instructions before it), or the code addresses lea'd into its register, in both
        cases with every other table's entries too (the binary tick check gives a jump the
        cases of the function's other dispatches as well, and its view must have no unticked
        cycle either); else, after a load from the GOT (the fat entry points), none (a tail
        call); else every table entry and address-taken label."""
        op = ins.ops.lstrip("*")
        regs = [REG[r][0] for r in REGTOK.findall(op) if r in REG and REG[r][0]]
        alltab = set(t for v in self.tables.values() for t in v)
        j = ins.idx - 1
        while j >= 0 and ins.idx - j <= 8:
            p = self.insns[j]
            t = self._table_of(p)
            if t is not None:
                return sorted(set(self.tables[t]) | alltab)
            if p.e["kind"] != "seq":
                break
            j -= 1
        if op.startswith("%") and regs and self.code_lea.get(regs[0]):
            return sorted(self.code_lea[regs[0]] | alltab)
        for p in self.insns[max(0, ins.idx - 4):ins.idx]:
            if p.reloc and "GOTPCREL" in p.reloc[0]:
                return None
        return sorted(self.table_targets) or None

    def _cfg(self):
        for ins in self.insns:
            ins.e = eff(ins.mn, ins.ops) or unknown()
        n = len(self.insns)
        for i, ins in enumerate(self.insns):
            k = ins.e["kind"]
            nxt = self.insns[i + 1] if i + 1 < n and self.insns[i + 1].sec == ins.sec else None
            tgt = None
            if k in ("jmp", "jcc", "call"):
                if ins.reloc:
                    if ins.reloc[1] in self.sym:
                        tgt = self.at.get(self.sym[ins.reloc[1]])
                else:
                    m = re.match(r"^(?:0x)?([0-9a-f]+)\b", ins.ops)
                    if m:
                        tgt = self.at.get((ins.sec, int(m.group(1), 16)))
            if k == "jmp":
                if tgt is not None:
                    ins.succ.append(tgt)
                else:
                    ins.tailcall = True
            elif k == "jcc":
                ins.succ += [x for x in (tgt, nxt) if x is not None]
            elif k == "ijmp":
                ts = self._ijmp_targets(ins)
                if ts:
                    ins.succ += [self.at[t] for t in dict.fromkeys(ts)]
                else:
                    ins.tailcall = True
            elif k not in ("ret", "halt") and nxt is not None:
                ins.succ.append(nxt)  # also a call: it returns
        for ins in self.insns:
            for s in ins.succ:
                s.pred.append(ins)

    def liveness(self):
        n = len(self.insns)
        lf, lr = [frozenset()] * n, [frozenset()] * n
        changed = True
        while changed:
            changed = False
            for i in reversed(range(n)):
                ins = self.insns[i]
                if ins.succ:
                    of = frozenset().union(*[lf[s.idx] for s in ins.succ])
                    orr = frozenset().union(*[lr[s.idx] for s in ins.succ])
                else:  # a return reads its registers itself; a tail call its arguments
                    of, orr = frozenset(), (ARGS | CALLEE_SAVED if ins.tailcall else frozenset())
                e = ins.e
                f, r = e["fr"] | (of - e["fw"]), e["rr"] | (orr - e["rw"])
                if f != lf[i] or r != lr[i]:
                    lf[i], lr[i], changed = f, r, True
        self.lf_in, self.lr_in = lf, lr



# =============================================================================== planning

LABELDEF = re.compile(r"^(\s*(?:L\([\w]+\)|[A-Za-z_][\w]*)\s*:\s*)+")
TWIN = None
_lines_cache = {}


def src_line(path, line):
    if path not in _lines_cache:
        try:
            _lines_cache[path] = open(path).read().split("\n")
        except OSError:
            _lines_cache[path] = []
    ls = _lines_cache[path]
    return ls[line - 1] if 0 < line <= len(ls) else None


def positions(u):
    """Where a tick before an instruction can go in the source: insn index ->
    "file:line:before" (a line of its own before that line) or "file:line:split" (after the
    labels that start it).  The line must expand once, to contiguous code, start outside
    any unquoted macro argument list, and its labels must all be at the instruction."""
    seen = defaultdict(list)
    for ins in u.insns:
        if ins.file is not None:
            seen[(ins.file, ins.line)].append(ins.idx)
    marks = Counter((TWIN["fids"][int(m.group(1))], int(m.group(2))) for m in MARK.finditer(u.out))
    labels = defaultdict(list)
    for kind, text, _, f, l, _ in u.items:
        if kind == "label" and f is not None:
            labels[(f, l)].append(text)
    out = {}
    for key, idxs in seen.items():
        if idxs != list(range(idxs[0], idxs[0] + len(idxs))) or marks[key] != 1:
            continue
        st = TWIN["starts"].get(key[0], {}).get(key[1])
        text = src_line(*key)
        if st is None or not safe_start(st) or text is None:
            continue
        ins = u.insns[idxs[0]]
        here = labels.get(key, [])
        if here:
            if not set(here) <= set(u.addr_labels.get((ins.sec, ins.addr), [])) or not LABELDEF.match(text):
                continue
            form = "split"
        else:
            form = "before"
        out[ins.idx] = "%s:%d:%s" % (key[0], key[1], form)
    return out


def analyze(args):
    mpn, work, unit = args
    plain = m4_output(mpn, unit)
    marked = m4_output(TWIN["mpn"], unit)
    a, b = normalize(plain), normalize(marked)
    if a != b:
        i = next((i for i in range(min(len(a), len(b))) if a[i] != b[i]), min(len(a), len(b)))
        return unit, dict(error="the markers changed the expansion: %r vs %r" % (a[i:i + 2], b[i:i + 2]))
    u = Unit(TWIN["mpn"], unit, work, marked, TWIN["fids"])
    u.liveness()
    spans = []  # the reach of the branches with only an 8-bit displacement
    for i in u.insns:
        if i.mn in ("jrcxz", "jecxz") or i.mn.startswith("loop"):
            for t in i.succ:
                if t.idx != i.idx + 1:
                    spans.append((min(i.addr, t.addr), max(i.addr, t.addr)))

    def recent(s, n=6):  # registers written just before (a partial write depends on them)
        out = set()
        for j in range(max(0, s.idx - n), s.idx):
            out |= u.insns[j].e["rw"]
        return sorted(out)

    return unit, dict(
        n=len(u.insns),
        succ=[sorted(set(s.idx for s in i.succ)) for i in u.insns],
        addr=[i.addr for i in u.insns],
        desc=["%s %s" % (i.mn, i.ops) for i in u.insns],
        lf=[sorted(u.lf_in[i.idx] & ALLF) for i in u.insns],
        fr=[sorted(ALLR - u.lr_in[i.idx] - {"rsp"}) for i in u.insns],
        rec=[recent(i) for i in u.insns],
        src=[(i.file, i.line) for i in u.insns],
        labels={i.idx: u.addr_labels[(i.sec, i.addr)] for i in u.insns if u.addr_labels.get((i.sec, i.addr))},
        pos=positions(u),
        spans=spans,
        unknown=sorted(set(i.mn for i in u.insns if i.e.get("unknown"))))


def sccs(n, succ):
    index, low, onst, comp = [None] * n, [0] * n, [False] * n, [None] * n
    st, c, idx = [], 0, 0
    for root in range(n):
        if index[root] is not None:
            continue
        work = [(root, 0)]
        while work:
            v, pi = work.pop()
            if pi == 0:
                index[v] = low[v] = idx; idx += 1
                st.append(v); onst[v] = True
            rec = False
            for j in range(pi, len(succ[v])):
                w = succ[v][j]
                if index[w] is None:
                    work.append((v, j + 1)); work.append((w, 0)); rec = True
                    break
                elif onst[w]:
                    low[v] = min(low[v], index[w])
            if rec:
                continue
            if low[v] == index[v]:
                while True:
                    w = st.pop(); onst[w] = False; comp[w] = c
                    if w == v:
                        break
                c += 1
            if work:
                low[work[-1][0]] = min(low[work[-1][0]], low[v])
    return comp


def pending_headers(g, cut):
    """The headers of the cycles left once the ticked instructions (cut) are removed, each
    with its region and the forced path from it within the region."""
    n = g["n"]
    succ = [[] if v in cut else [w for w in g["succ"][v] if w not in cut] for v in range(n)]
    comp = sccs(n, succ)
    size = Counter(comp)
    cyc = set(comp[v] for v in range(n) if size[comp[v]] > 1 or v in succ[v])
    pred = [[] for _ in range(n)]
    for v in range(n):
        for w in succ[v]:
            pred[w].append(v)
    be = defaultdict(list)
    for v in range(n):
        for w in succ[v]:
            if g["addr"][w] <= g["addr"][v] and comp[v] == comp[w] and comp[v] in cyc:
                be[w].append(v)
    out = []
    for h, us in be.items():
        reg = {h} | set(us)
        work = [x for x in us if x != h]
        while work:
            for p in pred[work.pop()]:
                if p not in reg:
                    reg.add(p); work.append(p)
        seg, seen, v = [], set(), h
        while v is not None and v not in seen:
            seen.add(v); seg.append(v)
            inside = [w for w in succ[v] if w in reg]
            v = inside[0] if len(inside) == 1 else None
            if v == h:
                break
        out.append(dict(h=h, comp=comp[h], region=len(reg), seg=seg))
    return out


COST = {"plain": 0, "cf": 1, "co": 2}


def choose_mode(lf, fr, rec):
    lf = set(lf)
    pref = [r for r in fr if r not in rec] + [r for r in fr if r in rec]
    if not lf:
        return ("plain", [])
    if lf <= {"C"} and pref:
        return ("cf", pref[:1])
    if lf <= {"C", "O"} and len(pref) >= 2:
        return ("co", pref[:2])
    return None


def plan(src, build, outp, jobs):
    global TWIN
    mpn = os.path.join(os.path.abspath(build), "mpn")
    work = os.path.join(os.path.dirname(os.path.abspath(outp)), "gmpticks.work")
    TWIN = build_twin(src, build, os.path.join(work, "twin"))
    units = sorted(f for f in os.listdir(mpn) if f.endswith(".asm"))
    with Pool(jobs) as p:
        res = dict(p.map(analyze, [(mpn, os.path.join(work, "obj"), u) for u in units]))
    errs = sorted((u, r["error"]) for u, r in res.items() if "error" in r)
    if errs:
        for u, e in errs:
            print("%s: %s" % (u, e), file=sys.stderr)
        raise SystemExit(1)
    G = res
    for g in G.values():
        g["idx_of"] = {v: k for k, v in g["pos"].items()}
    merged = {}  # a position's constraints over every unit that expands it
    for unit, g in G.items():
        for idx, p in g["pos"].items():
            a = g["addr"][idx]
            m = merged.setdefault(p, dict(lf=set(), fr=None, rec=set(), spans=0))
            m["lf"] |= set(g["lf"][idx])
            m["fr"] = set(g["fr"][idx]) if m["fr"] is None else m["fr"] & set(g["fr"][idx])
            m["rec"] |= set(g["rec"][idx])
            m["spans"] += sum(1 for lo, hi in g["spans"] if lo < a <= hi)
    chosen, why, problems, rounds = {}, {}, [], 0
    while True:
        rounds += 1
        want = defaultdict(list)
        for unit, g in sorted(G.items()):
            cut = set(g["idx_of"][p] for p in chosen if p in g["idx_of"])
            best = {}
            for h in pending_headers(g, cut):
                k = (-h["region"], g["addr"][h["h"]])
                if h["comp"] not in best or k < best[h["comp"]][0]:
                    best[h["comp"]] = (k, h)
            for _, h in best.values():
                f, l = g["src"][h["h"]]
                want["%s:%s" % (f, l) if f is not None else "%s@%x" % (unit, g["addr"][h["h"]])].append((unit, h))
        if not want:
            break
        progress = False
        for key, hs in sorted(want.items()):
            common = None
            for unit, h in hs:
                cs = [G[unit]["pos"][v] for v in h["seg"] if v in G[unit]["pos"]]
                common = cs if common is None else [c for c in common if c in cs]
            best = None
            for i, c in enumerate(common):
                m = merged[c]
                cm = choose_mode(m["lf"], sorted(m["fr"]), m["rec"])
                if cm is not None:
                    k = (COST[cm[0]], 1 if m["spans"] else 0, i)
                    if best is None or k < best[0]:
                        best = (k, c, cm)
            unit, h = hs[0]
            g = G[unit]
            if best is None:
                problems.append(dict(key=key, units=sorted(set(u for u, _ in hs)),
                                     path=[(hex(g["addr"][v]), g["desc"][v], g["lf"][v], g["fr"][v], g["pos"].get(v))
                                           for v in h["seg"]]))
                continue
            _, c, cm = best
            chosen[c] = cm
            why[c] = dict(header=g["desc"][h["h"]], labels=g["labels"].get(h["h"], []), round=rounds,
                          units=sorted(set(u for u, _ in hs)), live=sorted(merged[c]["lf"]),
                          dead=sorted(merged[c]["fr"]))
            progress = True
        if not progress:
            break
    srcroot = os.path.abspath(src)
    ticks = {os.path.relpath(c.rsplit(":", 2)[0], srcroot) + ":" + c.rsplit(":", 2)[1] + ":" + c.rsplit(":", 2)[2]:
             dict(mode=m[0], regs=m[1], **why[c]) for c, m in sorted(chosen.items())}
    with open(outp, "w") as f:
        json.dump(dict(ticks=ticks, problems=problems), f, indent=1, sort_keys=True)
    print("%d units, %d rounds: %d ticks (%s), %d problems" % (
        len(G), rounds, len(ticks), ", ".join("%s %d" % kv for kv in sorted(Counter(t["mode"] for t in ticks.values()).items())),
        len(problems)))
    unk = sorted(set(m for g in G.values() for m in g["unknown"]))
    if unk:
        print("unknown instructions (taken to read everything): %s" % " ".join(unk))
    for p in problems:
        print("no place for a tick: %s (%s)" % (p["key"], " ".join(p["units"])), file=sys.stderr)
        for s in p["path"]:
            print("    %s" % (s,), file=sys.stderr)
    return 1 if problems else 0


# =============================================================================== apply

def macro(mode, regs):
    if mode == "plain":
        return "RR_SOFTTICK"
    if mode == "cf":
        return "RR_SOFTTICK_CF(%%%s)" % regs[0]
    return "RR_SOFTTICK_CO(%%%s,%%%s)" % tuple(regs)


def apply(planp, dest):
    ticks = json.load(open(planp))["ticks"]
    per = defaultdict(dict)
    for pos, t in ticks.items():
        f, line, form = pos.rsplit(":", 2)
        per[f][int(line)] = (form, macro(t["mode"], t["regs"]))
    for rel, lines in sorted(per.items()):
        p = os.path.join(dest, rel)
        text = open(p).read().split("\n")
        for line in sorted(lines, reverse=True):
            form, m = lines[line]
            if form == "before":
                text[line - 1:line - 1] = ["\t" + m]
            else:
                lm = LABELDEF.match(text[line - 1])
                if not lm:
                    raise SystemExit("%s:%d: no label to split after" % (rel, line))
                rest = text[line - 1][lm.end():]
                text[line - 1:line] = [lm.group(0).rstrip(), "\t" + m] + (["\t" + rest.lstrip()] if rest.strip() else [])
        with open(p, "w") as fh:
            fh.write("\n".join(text))
    print("%d ticks in %d files" % (sum(len(v) for v in per.values()), len(per)))


def main():
    a = sys.argv[1:]
    if len(a) == 4 and a[0] == "plan":
        sys.exit(plan(a[1], a[2], a[3], int(os.environ.get("GMPTICKS_JOBS", "2"))))
    if len(a) == 3 and a[0] == "apply":
        apply(a[1], a[2])
        return
    sys.exit(__doc__)


if __name__ == "__main__":
    main()
