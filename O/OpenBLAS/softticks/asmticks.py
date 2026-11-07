#!/usr/bin/env python3
"""Insert rr software ticks into OpenBLAS's x86-64 hand-written assembly.

  asmticks.py [--check] FILE...

.S files: after every label that a jump later in the file targets (a backward branch in
  text order, i.e. a loop header), a line `RR_SOFTTICK`.
.c/.h files: in string literals (inline-asm templates, also inside #defines), after every
  label definition that a later `j.. Nb` / `j.. label` refers back to, `RR_SOFTTICK_ASM` (a
  string macro) is spliced in after the label.
Both macros come from common_x86_64.h (90-rr-softticks-macros.patch, which also ticks every
assembly function's entry in PROLOGUE) and are empty unless the compiler predefines
__RR_SOFTTICKS__.

Any cycle in a linearly laid out CFG contains a branch to a lower or equal address, so a tick
at every backward-branch target covers every cycle (function entries get theirs from
PROLOGUE). Text order equals address order here: the kernels have no section switches inside
functions, no indirect jumps and no loop/jrcxz. The rewriter is textual; the recipe's
post-build check (check.pl) verifies the object code (cycles, entries, flags).
Prints per file: labels ticked. Rewrites files in place unless --check.
regen.sh runs this over kernel/x86_64 to make 91-rr-softticks-kernels.patch.
"""
import re, sys

JCC = r"j(?:mp|[a-z]{1,4})"

# ---------- .S ----------

def code_view(lines):
    """Per line: the code with comments removed ('' for cpp directives)."""
    out = []
    inc = False
    for ln in lines:
        s = ln
        res = ""
        i = 0
        while i < len(s):
            if inc:
                j = s.find("*/", i)
                if j < 0: i = len(s); break
                inc = False; i = j + 2; continue
            if s.startswith("/*", i): inc = True; i += 2; continue
            if s.startswith("//", i): break
            if s[i] == "#" : break      # gas comment (or cpp directive, handled below)
            res += s[i]; i += 1
        if re.match(r"^\s*#", ln): res = ""
        out.append(res)
    return out

LABEL_S = re.compile(r"^\s*([A-Za-z_.$][\w.$]*):")
JUMP_S = re.compile(r"^\s*" + JCC + r"\s+([A-Za-z_.$][\w.$]*)\s*$")

def rewrite_S(text):
    lines = text.split("\n")
    code = code_view(lines)
    # cpp aliases of jump mnemonics: #define JLE jle
    aliases = set(re.findall(r"^#define\s+(\w+)\s+" + JCC + r"\s*$", text, re.M))
    jump_s = re.compile(r"^\s*(?:" + JCC + "".join("|" + re.escape(a) for a in sorted(aliases)) +
                        r")\s+([A-Za-z_.$][\w.$]*)\s*$")
    defs, jumps = [], {}
    for i, c in enumerate(code):
        for stmt in c.split(";"):
            while True:
                m = LABEL_S.match(stmt)
                if not m: break
                defs.append((i, m.group(1), m.end()))
                stmt = stmt[m.end():]
            m = jump_s.match(stmt)
            if m:
                jumps.setdefault(m.group(1), []).append(i)
    ticked = []
    insert = {}
    for (i, lab, end) in defs:
        if any(j >= i for j in jumps.get(lab, [])):
            if lines[i].rstrip().endswith("\\"):
                raise SystemExit("label %s in a macro continuation line %d" % (lab, i + 1))
            insert[i] = True
            ticked.append(lab)
    out = []
    for i, ln in enumerate(lines):
        if i in insert:
            m = re.match(r"^(\s*(?:[A-Za-z_.$][\w.$]*:\s*)+)(.*)$", ln)
            if m and m.group(2).strip() and not m.group(2).strip().startswith(("/*", "//", "#")):
                out.append(m.group(1).rstrip())
                out.append("\tRR_SOFTTICK")
                out.append("\t" + m.group(2))
                continue
            out.append(ln)
            out.append("\tRR_SOFTTICK")
        else:
            out.append(ln)
    return "\n".join(out), ticked

# ---------- .c ----------

def c_tokens(text):
    """Yield (kind, start, end) for string literals ('s') and everything else ('o'),
    skipping comments and char literals (as 'o')."""
    i, n = 0, len(text)
    start = 0
    while i < n:
        c = text[i]
        if text.startswith("/*", i):
            j = text.find("*/", i + 2); i = n if j < 0 else j + 2; continue
        if text.startswith("//", i):
            j = text.find("\n", i); i = n if j < 0 else j; continue
        if c == "'":
            j = i + 1
            while j < n and text[j] != "'":
                j += 2 if text[j] == "\\" else 1
            i = j + 1; continue
        if c == '"':
            if start < i: yield ("o", start, i)
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            yield ("s", i, j + 1)
            i = j + 1; start = i; continue
        i += 1
    if start < n: yield ("o", start, n)

# a label definition inside an asm string: at the start of a statement
# numeric labels may be pasted from pieces: "7"#mdim"7"#ndim"1:" (\x00 = the non-literal parts)
LBL = r"([\d\x00]*\d[\d\x00]*|[.A-Za-z_][\w.]*(?:%=)?)"
DEF_C = re.compile(r"(?:^|(?<=\\n)|(?<=\\t)|(?<=;)|(?<=\s)|(?<=\x00))\s*" + LBL + r":(?!:)")
TGT = r"([\d\x00]*\d[\d\x00]*[fb]|[.A-Za-z_][\w.]*(?:%=)?)"
JMP_C = re.compile(r"\b" + JCC + r"\s+\x00?" + TGT + r"(?=[\s;\\\"\x00]|$)")

def rewrite_c(text):
    toks = list(c_tokens(text))
    # the asm stream: literal contents joined, a \x00 for anything between literals
    stream = []
    pos = []  # (stream offset, token index, offset in literal content)
    for ti, (k, a, b) in enumerate(toks):
        if k == "s":
            content = text[a + 1:b - 1]
            pos.append((sum(len(x) for x in stream), ti, a + 1))
            stream.append(content)
        else:
            if not stream or stream[-1] != "\x00":
                stream.append("\x00")
    s = "".join(stream)
    # map stream offset -> text offset
    def text_off(so):
        lo = None
        for (st, ti, ta) in pos:
            if st <= so: lo = (st, ti, ta)
            else: break
        st, ti, ta = lo
        return ta + (so - st), ti
    defs = []
    for m in DEF_C.finditer(s):
        lab = m.group(1).lstrip("\x00")
        if lab.replace("\x00", "").isdigit() or "%=" in lab or lab.startswith("."):
            defs.append((m.start(1), m.end(), lab))
    jumps = []
    for m in JMP_C.finditer(s):
        t = m.group(1).lstrip("\x00")
        jumps.append((m.start(), t))
    targets = set()
    for (p, t) in jumps:
        if re.fullmatch(r"[\d\x00]*\d[\d\x00]*b", t):
            lab = t[:-1]
            prev = [d for d in defs if d[2] == lab and d[0] < p]
            if prev: targets.add(max(prev))
        elif not re.fullmatch(r"[\d\x00]*\d[\d\x00]*f", t):
            prev = [d for d in defs if d[2] == t and d[0] < p]
            for d in prev: targets.add(d)
    # splice RR_SOFTTICK_ASM after each target label's colon
    edits = []
    for (ls, le, lab) in sorted(targets):
        to, ti = text_off(le)          # text offset right after the colon
        k, a, b = toks[ti]
        lit_end = b - 1                # offset of the closing quote
        rest = text[to:lit_end]
        if re.fullmatch(r"(\s|\\n|\\t)*", rest):
            edits.append((b, b, " RR_SOFTTICK_ASM "))
        else:
            edits.append((to, to, '" RR_SOFTTICK_ASM "'))
    out = text
    for (a, b, rep) in sorted(edits, reverse=True):
        out = out[:a] + rep + out[b:]
    return out, [t[2].replace("\x00", "#") for t in sorted(targets)]

def main(argv):
    check = "--check" in argv
    total = 0
    for f in [a for a in argv if not a.startswith("--")]:
        text = open(f).read()
        if "RR_SOFTTICK" in text:
            print("%s: already instrumented" % f); continue
        new, labs = rewrite_S(text) if f.endswith(".S") else rewrite_c(text)
        total += len(labs)
        if labs:
            print("%s: %d %s" % (f, len(labs), " ".join(labs)))
            if not check:
                open(f, "w").write(new)
    print("total labels ticked: %d" % total)

if __name__ == "__main__":
    main(sys.argv[1:])
