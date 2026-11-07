#!/usr/bin/env perl
# The software ticks check of an x86-64 OpenBLAS built with a software-ticks compiler pass:
# rr's tracee ABI (include/rr/softticks.h, version 1) needs a tick on every cycle of the
# code, at every function entry, and a tick must not clobber flags that are still live.
# The pass takes care of compiled C and Fortran; this checks the object code, so that it
# covers the hand-written kernels (the ticks of 90/91-rr-softticks-*.patch) and whatever else.
#
#   check.pl [--jobs N] [--so LIB] ARCHIVE|OBJECT...
#   check.pl --selftest
#
# Per object and executable section, from `objdump -d -r -t -h` (GNU or LLVM; $OBJDUMP):
#   unticked_scc    a cycle of the instruction-level CFG with no tick on it
#   entry_unticked  a path from a function symbol to an exit without a tick
#   flags_live      an arithmetic flag live after a tick (which clobbers them all)
#   bad_tick        a tick-like sequence that is not the ABI's bytes (by length), or an
#                   access to the countdown (0x70001800-0x70001807) outside a whole tick
#   no_note         compiled code (a .comment) without the software ticks note
#   undecodable     an instruction objdump cannot decode (too old for AMX, AVX-512 FP16)
# and, in objects without a .comment (assembled from .S, i.e. hand-written):
#   indirect, loop_insn   control flow the CFG cannot follow
#   reloc_jump      a jump through a relocation (to a global symbol), which the CFG drops
# Ticks are the ABI sequence (testb $0x80,0x70001807; jne; decq 0x70001800; jne; int3).
# Jumps carrying a relocation (to another section or symbol) and indirect jumps are exits;
# a call is an ordinary instruction that clobbers the flags. Instructions this script does
# not know are taken to read every flag (so they can only add flags_live findings).
# Compiled code is checked per section: a cycle through a jump to another section (a cold
# part) or through a switch's indirect jump goes unseen, which is the compiler pass's to
# get right; the hand-written kernels have neither.
#
# --so LIB: also check that the shared library carries the software ticks note (ABI
# version 1) and the initializer that maps the countdown's page outside rr.
# --selftest: assembles (with $CC, else cc) an object with one fault of each kind the
# hand-written kernels could have (an unticked loop, an entry path without a tick, a flag
# live after a tick, a stray countdown access) and one without, and checks that exactly
# those are found: that this objdump's output is read as this script expects.
# Exits 1 if anything is found, 2 on usage or tool errors (or a failed self-test).
use strict;
use warnings;
no warnings 'portable';    # hex() of 64-bit addresses
use File::Temp qw(tempdir);
use POSIX ();
use Getopt::Long;

my ($so, $jobs, $selftest) = (undef, 1, 0);
GetOptions("so=s" => \$so, "jobs=i" => \$jobs, "selftest" => \$selftest) or exit 2;
die "usage: $0 [--jobs N] [--so LIB] ARCHIVE|OBJECT... | --selftest\n" unless @ARGV || $selftest;
my $OBJDUMP = $ENV{OBJDUMP} || "objdump";

# ---------------------------------------------------------------- flags
my %CC = (o => "O", no => "O", b => "C", c => "C", nae => "C", ae => "C", nb => "C",
          nc => "C", e => "Z", z => "Z", ne => "Z", nz => "Z", be => "CZ", na => "CZ",
          a => "CZ", nbe => "CZ", s => "S", ns => "S", p => "P", pe => "P", np => "P",
          po => "P", l => "SO", nge => "SO", ge => "SO", nl => "SO", le => "ZSO",
          ng => "ZSO", g => "ZSO", nle => "ZSO");
my $CCR = join "|", sort { length($b) <=> length($a) } keys %CC;
my %FCMOV = (b => "C", e => "Z", be => "CZ", u => "P", nb => "C", ne => "Z", nbe => "CZ",
             nu => "P");
my $FCR = join "|", sort { length($b) <=> length($a) } keys %FCMOV;
my %W_ALL = map { $_ => 1 } qw(add sub and or xor cmp test neg imul mul div idiv popcnt
    lzcnt tzcnt bsf bsr andn bextr blsi blsmsk blsr bzhi xadd cmpxchg cmpxchg8b cmpxchg16b
    comisd comiss ucomisd ucomiss vcomisd vcomiss vucomisd vucomiss ptest vptest vtestps
    vtestpd kortestw kortestb kortestd kortestq ktestw ktestb ktestd ktestq fcomi fcomip
    fucomi fucomip popf popfq sahf aaa aas daa das vcomish vucomish pcmpestri pcmpestrm
    pcmpistri pcmpistrm vpcmpestri vpcmpestrm vpcmpistri vpcmpistrm rdrand rdseed);
my %NEUTRAL = map { $_ => 1 } qw(mov movabs movs movz movsx movzx movsxd movslq movsbl
    movsbq movswl movswq movzbl movzbq movzwl movzwq movsbw movzbw lea push pop nop xchg cltq
    cqto cqo cdq cltd cwtl cwtd cbtw cdqe bswap not prefetcht0 prefetcht1 prefetcht2
    prefetchnta prefetchw prefetch endbr64 endbr32 vzeroupper vzeroall emms femms leave
    ret jmp call ud2 int3 hlt pause lfence sfence mfence sarx shlx shrx rorx mulx pdep pext
    cpuid rdtsc rdtscp xgetbv syscall cld std ldtilecfg sttilecfg tilerelease tilezero
    tileloadd tileloaddt1 tilestored stos lods xlat wait fwait loop jrcxz jecxz);

# Returns (reads, writes) as strings of flag letters; undef if unknown.
sub flag_effect {
    my ($mn, $ops) = @_;
    return ($CC{$1}, "") if $mn =~ /^j($CCR)$/;
    return ($CC{$1}, "") if $mn =~ /^(?:cmov|set)($CCR)[bwlq]?$/;
    return ($FCMOV{$1}, "") if $mn =~ /^fcmov($FCR)$/;
    return ("Z", "") if $mn =~ /^loopn?[ez]$/;
    # string compares (cmpsd/cmpss with xmm operands are SSE compares)
    return ("", "CPAZSO") if $mn =~ /^(?:cmps|scas)[bwlqd]?$/ && $ops !~ /%xmm/;
    my $cl = $ops =~ /%cl\b/;
    for my $b ($mn, substr($mn, 0, -1)) {
        next if $b eq "";
        return ("C", "CPAZSO") if $b eq "adc" || $b eq "sbb" || $b eq "adcx" || $b eq "adox";
        return $cl ? ("C", "") : ("C", "CO") if $b eq "rcl" || $b eq "rcr";
        return $cl ? ("", "") : ("", "CO") if $b eq "rol" || $b eq "ror";
        return $cl ? ("", "") : ("", "CPAZSO")
            if $b =~ /^(?:sal|shl|sar|shr|shld|shrd)$/;
        return ("", "PAZSO") if $b eq "inc" || $b eq "dec";
        return ("", "C") if $b =~ /^(?:bt|bts|btr|btc|clc|stc)$/;
        return ("C", "C") if $b eq "cmc";
        return ("CPAZSO", "") if $b =~ /^(?:pushf|pushfq|pushfw|lahf|into)$/;
        return ("", "CPAZSO") if $W_ALL{$b};
        return ("", "") if $NEUTRAL{$b};
    }
    return ("", "") if $mn =~ /^nop/;
    # SSE/AVX/AVX-512/x87/AMX: no flags (the flag-writing ones are in %W_ALL above).
    return ("", "") if $mn =~ /^(?:v|k|p|f|tdp|tile)/ ||
        $mn =~ /^(?:mov|add|sub|mul|div|max|min|sqrt|and|or|xor|unpck|shuf|cvt|hadd|hsub|blend|
                   insert|extract|round|rcp|rsqrt|ldmxcsr|stmxcsr|lddqu|dpp|addsub|cmpp|
                   cmps[sd]$|cmpeq|cmplt|cmple|cmpneq|cmpnlt|cmpnle|cmpord|cmpunord|movnt|
                   maskmov|crc32|aes|sha|pclmul|clflush|clwb)/x;
    return undef;
}

# ---------------------------------------------------------------- objdump parsing
my %PREFIX = map { $_ => 1 } qw(rep repz repe repnz repne lock notrack bnd data16 data32
    addr16 addr32 cs ds es ss fs gs xacquire xrelease);

# Normalizes "mnemonic operands" text: returns (mnemonic, operands).
sub split_insn {
    my ($text) = @_;
    $text =~ s/\s+#.*$//;      # objdump's comments (# address, # symbol)
    $text =~ s/\s+<[^>]*>\s*$//;   # the symbolic form of a branch target
    my @t = split ' ', $text, 2;
    while (@t && ($PREFIX{$t[0]} || $t[0] =~ /^(?:rex(?:\.\w+)?|\{\w+\})$/)) {
        @t = split ' ', ($t[1] // ""), 2;
    }
    my ($mn, $ops) = ($t[0] // "", $t[1] // "");
    $mn =~ s/,p[tn]$//;        # branch hints
    $mn = "call" if $mn =~ /^call[lqw]?$/;
    $mn = "ret" if $mn =~ /^ret[lqw]?$/;
    $mn = "jmp" if $mn =~ /^jmp[lqw]?$/;
    $ops =~ s/\s+//g;
    return ($mn, $ops);
}

# Runs objdump on one object; returns a hash: sections => {name => [insns]}, syms => [...],
# has_comment, has_note. An insn is [addr, mnemonic, operands, reloc-target-or-undef].
sub read_object {
    my ($path) = @_;
    open(my $fh, "-|", $OBJDUMP, "-d", "-r", "-t", "-h", "--no-show-raw-insn", $path)
        or die "$OBJDUMP: $!\n";
    my %o = (sections => {}, syms => [], has_comment => 0, has_note => 0, order => [], bad => {});
    my $mode = "";
    my $sec;
    while (my $ln = <$fh>) {
        chomp $ln;
        if ($ln =~ /^Sections:/) { $mode = "h"; next; }
        if ($ln =~ /^SYMBOL TABLE:/) { $mode = "t"; next; }
        if ($ln =~ /^Disassembly of section (\S+?):?$/) {
            $mode = "d"; $sec = $1;
            unless ($o{sections}{$sec}) { $o{sections}{$sec} = []; push @{$o{order}}, $sec; }
            next;
        }
        if ($mode eq "h") {
            if ($ln =~ /^\s*\d+\s+(\S+)\s+[0-9a-f]+\s/) {
                $o{has_comment} = 1 if $1 eq ".comment";
                $o{has_note} = 1 if $1 eq ".note.rrsoftticks";
            }
        } elsif ($mode eq "t") {
            # GNU: ADDR FLAGS SECTION\tSIZE [.hidden] NAME; LLVM: ADDR FLAGS SECTION SIZE NAME
            if ($ln =~ /^([0-9a-f]{8,16}) (.{7}) (\S+)\s+([0-9a-f]+)\s+(.*)$/) {
                my ($addr, $fl, $s, $n) = (hex $1, $2, $3, $5);
                my @nt = split ' ', $n;
                push @{$o{syms}}, [$addr, $fl, $s, $nt[-1] // ""];
            }
        } elsif ($mode eq "d") {
            next unless defined $sec;
            if ($ln =~ /^\s+([0-9a-f]+):\s+(R_X86_64_\S+)\s+(\S+)/) {
                my $ins = $o{sections}{$sec};
                $ins->[-1][3] = $3 if @$ins;
                next;
            }
            next if $ln =~ /^[0-9a-f]+ <.*>:$/;
            if ($ln =~ /^\s*([0-9a-f]+):\s+(\S.*)$/) {
                my ($addr, $text) = (hex $1, $2);
                # an instruction this objdump cannot decode (an old one, for AMX or AVX-512
                # FP16): everything after it would be misread
                if ($text =~ /\(bad\)/) { push @{$o{bad}{$sec}}, $addr; next; }
                # GNU objdump -w puts the relocation on the instruction's line
                my $rel;
                $rel = $1 if $text =~ s/\s+[0-9a-f]+:\s+R_X86_64_\S+\s+(\S+)\s*$//;
                my ($mn, $ops) = split_insn($text);
                next if $mn eq "";
                push @{$o{sections}{$sec}}, [$addr, $mn, $ops, $rel];
            }
        }
    }
    close $fh or die "$OBJDUMP failed on $path\n";
    return \%o;
}

# ---------------------------------------------------------------- analysis
my %NORETURN = map { $_ => 1 } qw(exit _exit abort __stack_chk_fail __assert_fail
    pthread_exit longjmp siglongjmp __longjmp_chk __cxa_throw _Unwind_Resume __fortify_fail
    __chk_fail);

sub is_tick_at {
    my ($ins, $i) = @_;
    return 0 if $i + 5 > @$ins;
    my @m = map { $ins->[$i + $_][1] } 0 .. 4;
    return 0 unless $m[0] eq "testb" && $m[1] =~ /^j(?:ne|nz)$/ && $m[2] eq "decq" &&
        $m[3] =~ /^j(?:ne|nz)$/ && $m[4] eq "int3";
    return 0 unless $ins->[$i][2] =~ /^\$(?:0x80|-0x80),(?:0x)?70001807$/ &&
        $ins->[$i + 2][2] =~ /^(?:0x)?70001800$/;
    return 1;
}

sub analyze_section {
    my ($ins, $entries, $asm, $label) = @_;
    my $n = @$ins;
    my %idx;
    $idx{$ins->[$_][0]} = $_ for 0 .. $n - 1;
    my %P;    # kind => [details]
    my @tick = (0) x $n;
    my @ends;
    my $ticks = 0;
    for (my $i = 0; $i < $n;) {
        if (is_tick_at($ins, $i)) {
            my $addr = $ins->[$i][0];
            my $end = $i + 5 < $n ? $ins->[$i + 5][0] : $addr + 21;
            # the ABI's bytes: testb 8, jne 2, decq 8, jne 2, int3 1; both jumps to the end
            my @off = map { $ins->[$i + $_][0] - $addr } 1 .. 4;
            my $ok = "@off" eq "8 10 18 20" && $end - $addr == 21;
            for my $k (1, 3) {
                my ($t) = $ins->[$i + $k][2] =~ /^(?:0x)?([0-9a-f]+)$/;
                $ok = 0 unless defined $t && hex($t) == $addr + 21 && !defined $ins->[$i + $k][3];
            }
            push @{$P{bad_tick}}, sprintf("%x", $addr) unless $ok;
            $tick[$i + $_] = 1 for 0 .. 4;
            push @ends, $i + 5 if $i + 5 < $n;
            $ticks++;
            $i += 5;
        } else {
            # the countdown (absolute 0x70001800-0x70001807) touched outside a whole tick
            push @{$P{bad_tick}}, sprintf("%x", $ins->[$i][0])
                if $ins->[$i][2] =~ /(?:^|[,(\s])(?:0x)?7000180[0-7](?:$|[,(\s])/;
            $i++;
        }
    }
    my @succ = map { [] } 1 .. $n;
    my @exit = (0) x $n;
    for my $i (0 .. $n - 1) {
        my ($addr, $mn, $ops, $rel) = @{$ins->[$i]};
        my $isj = $mn =~ /^(?:j|loop)/;
        my $tgt;
        $tgt = hex $1 if $isj && !defined $rel && $ops =~ /^(?:0x)?([0-9a-f]+)$/;
        push @{$P{reloc_jump}}, sprintf("%x:%s", $addr, $rel) if $isj && defined $rel && $asm;
        if ($mn eq "ret" || $mn eq "ud2" || $mn eq "hlt" || $mn eq "iret" || $mn eq "iretq" ||
            $mn eq "sysret") {
            $exit[$i] = 1 if $mn =~ /^(?:ret|iret)/;
            next;
        }
        if ($mn eq "jmp") {
            if ($ops =~ /^\*/) {
                push @{$P{indirect}}, sprintf("%x", $addr) if $asm;
                $exit[$i] = 1;
            } elsif (defined $tgt && exists $idx{$tgt}) {
                push @{$succ[$i]}, $idx{$tgt};
            } else {
                $exit[$i] = 1;
            }
            next;
        }
        if ($mn =~ /^(?:loop|jrcxz|jecxz)/) {
            push @{$P{loop_insn}}, sprintf("%x", $addr) if $asm;
        }
        if ($mn =~ /^(?:j(?:$CCR)|jrcxz|jecxz|loop\w*)$/) {
            if (defined $tgt && exists $idx{$tgt}) { push @{$succ[$i]}, $idx{$tgt}; }
            else { $exit[$i] = 1; }
        }
        if ($mn eq "call" && defined $rel) {
            my $s = $rel;
            $s =~ s/[-+].*$//;
            $s =~ s/\@.*$//;
            if ($NORETURN{$s}) { $exit[$i] = 1; next; }
        }
        if ($i + 1 < $n) { push @{$succ[$i]}, $i + 1; } else { $exit[$i] = 1; }
    }

    # cycles without a tick: SCCs (iterative Tarjan) of the graph without the tick nodes
    my @index = (-1) x $n;
    my @low = (0) x $n;
    my @onst = (0) x $n;
    my @st;
    my $c = 0;
    for my $v0 (0 .. $n - 1) {
        next if $tick[$v0] || $index[$v0] >= 0;
        my @work = ([$v0, 0]);
        $index[$v0] = $low[$v0] = $c++;
        push @st, $v0;
        $onst[$v0] = 1;
        while (@work) {
            my ($v, $pi) = @{$work[-1]};
            my $ss = $succ[$v];
            $pi++ while $pi < @$ss && $tick[$ss->[$pi]];
            if ($pi < @$ss) {
                $work[-1][1] = $pi + 1;
                my $w = $ss->[$pi];
                if ($index[$w] < 0) {
                    $index[$w] = $low[$w] = $c++;
                    push @st, $w;
                    $onst[$w] = 1;
                    push @work, [$w, 0];
                } elsif ($onst[$w]) {
                    $low[$v] = $index[$w] if $index[$w] < $low[$v];
                }
            } else {
                pop @work;
                if (@work) {
                    my $u = $work[-1][0];
                    $low[$u] = $low[$v] if $low[$v] < $low[$u];
                }
                if ($low[$v] == $index[$v]) {
                    my @comp;
                    while (1) {
                        my $w = pop @st;
                        $onst[$w] = 0;
                        push @comp, $w;
                        last if $w == $v;
                    }
                    if (@comp > 1 || grep { $_ == $v } @{$succ[$v]}) {
                        my $min = (sort { $a <=> $b } @comp)[0];
                        push @{$P{unticked_scc}}, sprintf("%x", $ins->[$min][0]);
                    }
                }
            }
        }
    }

    # function entries: every path to an exit passes a tick
    for my $e (@$entries) {
        unless (exists $idx{$e}) { push @{$P{entry_missing}}, sprintf("%x", $e); next; }
        my %seen;
        my @work = ($idx{$e});
        while (@work) {
            my $v = pop @work;
            next if $seen{$v} || $tick[$v];
            $seen{$v} = 1;
            if ($exit[$v]) { push @{$P{entry_unticked}}, sprintf("%x", $e); last; }
            push @work, @{$succ[$v]};
        }
    }

    # flags: liveness (backwards dataflow), then what is live right after each tick
    my (@rd, @wr);
    my %unknown;
    for my $i (0 .. $n - 1) {
        my (undef, $mn, $ops) = @{$ins->[$i]};
        my ($r, $w) = flag_effect($mn, $ops);
        unless (defined $r) { $unknown{$mn}++; ($r, $w) = ("CPAZSO", ""); }
        ($r, $w) = ("", "CPAZSO") if $mn eq "call";
        my ($rm, $wm) = (0, 0);
        for my $f (split //, $r) { $rm |= 1 << index("CPAZSO", $f); }
        for my $f (split //, $w) { $wm |= 1 << index("CPAZSO", $f); }
        $rd[$i] = $rm;
        $wr[$i] = $wm;
    }
    if (@ends) {
        my @live = (0) x $n;
        my $changed = 1;
        while ($changed) {
            $changed = 0;
            for (my $v = $n - 1; $v >= 0; $v--) {
                my $out = 0;
                $out |= $live[$_] for @{$succ[$v]};
                my $li = $rd[$v] | ($out & ~$wr[$v]);
                if ($li != $live[$v]) { $live[$v] = $li; $changed = 1; }
            }
        }
        for my $t (@ends) {
            next unless $live[$t];
            my $fl = join "", map { (($live[$t] >> $_) & 1) ? substr("CPAZSO", $_, 1) : () } 0 .. 5;
            push @{$P{flags_live}}, sprintf("%x:%s", $ins->[$t][0], $fl);
        }
    }
    return { label => $label, insns => $n, ticks => $ticks, problems => \%P,
             unknown => \%unknown };
}

sub check_object {
    my ($path, $name) = @_;
    my $o = read_object($path);
    my $asm = !$o->{has_comment};
    my @res;
    my $code = 0;
    for my $sec (@{$o->{order}}) {
        next if $sec =~ /^\.text\.__rr_softticks_init/;
        my $ins = $o->{sections}{$sec};
        if ($o->{bad}{$sec}) {
            push @res, { label => "$name:$sec", insns => 0, ticks => 0, unknown => {},
                         problems => { undecodable => [map { sprintf "%x", $_ } @{$o->{bad}{$sec}}] } };
        }
        next unless @$ins;
        $code += @$ins;
        my @ents = map { $_->[0] } grep {
            $_->[2] eq $sec && $_->[1] =~ /F/ && $_->[3] !~ /\.cold(?:\.\d+)?$/ &&
            $_->[3] !~ /^__rr_softticks_init/ } @{$o->{syms}};
        my %u;
        my @e = grep { !$u{$_}++ } @ents;
        push @res, analyze_section($ins, \@e, $asm, "$name:$sec");
    }
    if ($code && !$asm && !$o->{has_note}) {
        push @res, { label => "$name", insns => 0, ticks => 0,
                     problems => { no_note => ["compiled without the software ticks pass"] },
                     unknown => {} };
    }
    return { name => $name, asm => $asm, results => \@res };
}

# ---------------------------------------------------------------- archives
# Writes an archive's members to DIR (names made unique); returns [path, member name] pairs.
sub extract_archive {
    my ($ar, $dir, $seq) = @_;
    open(my $fh, "<:raw", $ar) or die "$ar: $!\n";
    local $/;
    my $data = <$fh>;
    close $fh;
    die "$ar: not an archive (or a thin one)\n" unless substr($data, 0, 8) eq "!<arch>\n";
    my $pos = 8;
    my $longnames = "";
    my @out;
    while ($pos + 60 <= length $data) {
        my $h = substr($data, $pos, 60);
        my $name = substr($h, 0, 16);
        my $size = substr($h, 48, 10) + 0;
        my $body = substr($data, $pos + 60, $size);
        $pos += 60 + $size + ($size & 1);
        $name =~ s/\s+$//;
        if ($name eq "/" || $name eq "/SYM64/") { next; }
        if ($name eq "//") { $longnames = $body; next; }
        if ($name =~ m{^/(\d+)$}) {
            my $off = $1;
            my $end = index($longnames, "/\n", $off);
            $name = substr($longnames, $off, $end - $off);
        } else {
            $name =~ s{/$}{};
        }
        my $p = sprintf("%s/%06d-%s", $dir, $$seq++, $name);
        open(my $o, ">:raw", $p) or die "$p: $!\n";
        print $o $body;
        close $o;
        push @out, [$p, $name];
    }
    return @out;
}

# ---------------------------------------------------------------- self-test
my $SELFTEST_TICK = "testb \$0x80, 0x70001807; jnz 7731f; decq 0x70001800; jnz 7731f; int3; 7731:";
my %SELFTEST = (
    good => [<<'EOS', {}],
	.text
	.globl good1
	.type good1, @function
good1:	TICK
	movl $10, %ecx
1:	TICK
	addl $1, %eax
	decl %ecx
	jnz 1b
	cmpl $1, %edi
	je 2f
	addl $1, %eax
2:	ret
	.size good1, .-good1
EOS
    bad => [<<'EOS', {unticked_scc => 1, entry_unticked => 1, flags_live => 1, bad_tick => 1}],
	.text
	.globl loop
	.type loop, @function
loop:	TICK
	movl $10, %ecx
1:	addl $1, %eax
	decl %ecx
	jnz 1b
	ret
	.globl entry
	.type entry, @function
entry:	testl %edi, %edi
	jz 2f
	TICK
2:	ret
	.globl flags
	.type flags, @function
flags:	TICK
	cmpl $1, %edi
	TICK
	je 3f
	addl $1, %eax
3:	ret
	.globl stray
	.type stray, @function
stray:	TICK
	movq 0x70001800, %rax
	ret
EOS
);

sub selftest {
    my $dir = tempdir(CLEANUP => 1);
    my $cc = $ENV{CC} || "cc";
    my $ok = 1;
    for my $name (sort keys %SELFTEST) {
        my ($src, $want) = @{$SELFTEST{$name}};
        $src =~ s/\bTICK\b/$SELFTEST_TICK/g;
        open(my $fh, ">", "$dir/$name.s") or die "$dir/$name.s: $!\n";
        print $fh $src;
        close $fh;
        system("$cc -c -o $dir/$name.o $dir/$name.s") == 0 or die "$cc failed on the self-test\n";
        my $r = check_object("$dir/$name.o", "$name.o");
        my %got;
        my $ticks = 0;
        for my $s (@{$r->{results}}) {
            $ticks += $s->{ticks};
            $got{$_} += scalar @{$s->{problems}{$_}} for keys %{$s->{problems}};
        }
        my $g = join(" ", map { "$_=$got{$_}" } sort keys %got);
        my $w = join(" ", map { "$_=$want->{$_}" } sort keys %$want);
        my $t = () = $src =~ /7731:/g;
        my $pass = $g eq $w && $ticks == $t && $r->{asm};
        printf "softticks check self-test %s: %d of %d ticks, findings {%s}, %s\n", $name, $ticks,
            $t, $g, $pass ? "as expected" : "expected {$w}";
        $ok &&= $pass;
    }
    return $ok ? 0 : 2;
}
exit selftest() if $selftest;

# ---------------------------------------------------------------- main
my $tmp = tempdir(CLEANUP => 1);
my $seq = 0;
my @objs;
for my $f (@ARGV) {
    open(my $fh, "<:raw", $f) or die "$f: $!\n";
    my $magic = "";
    read($fh, $magic, 8);
    close $fh;
    if ($magic eq "!<arch>\n") {
        push @objs, map { [$_->[0], "$f($_->[1])", $_->[1]] } extract_archive($f, $tmp, \$seq);
    }
    else { push @objs, [$f, $f]; }
}

# workers: each takes every Nth object and writes its findings to a file
my @kids;
$jobs = 1 if $jobs < 1;
for my $j (0 .. $jobs - 1) {
    my $pid = fork();
    die "fork: $!\n" unless defined $pid;
    if ($pid == 0) {
        $SIG{__DIE__} = sub { print STDERR @_; POSIX::_exit(2); };
        open(my $out, ">", "$tmp/result.$j") or die "$tmp/result.$j: $!\n";
        for (my $k = $j; $k < @objs; $k += $jobs) {
            my ($p, $name, $member) = @{$objs[$k]};
            $member //= $name =~ s{.*/}{}r;
            my $r = check_object($p, $name);
            for my $s (@{$r->{results}}) {
                printf $out "S\t%s\t%d\t%d\t%d\n", $name, $r->{asm}, $s->{insns}, $s->{ticks};
                for my $kind (sort keys %{$s->{problems}}) {
                    printf $out "P\t%s\t%d\t%s\t%s\t%s\n", $member, $r->{asm}, $s->{label}, $kind,
                        join(" ", @{$s->{problems}{$kind}});
                }
                for my $mn (sort keys %{$s->{unknown}}) {
                    printf $out "U\t%s\t%s\n", $mn, $s->{unknown}{$mn};
                }
            }
            printf $out "O\t%s\t%d\n", $name, $r->{asm};
        }
        close $out;
        POSIX::_exit(0);
    }
    push @kids, $pid;
}
my $failed_kid = 0;
for (@kids) { waitpid($_, 0); $failed_kid = 1 if $?; }
if ($failed_kid) { print STDERR "softticks check: a worker failed\n"; exit 2; }

my (%nobj, $sections, $insns, $ticks, %unknown, @fail);
($sections, $insns, $ticks) = (0, 0, 0);
for my $j (0 .. $jobs - 1) {
    open(my $fh, "<", "$tmp/result.$j") or die;
    while (<$fh>) {
        chomp;
        my @f = split /\t/;
        if ($f[0] eq "O") { $nobj{$f[2] ? "asm" : "c"}++; }
        elsif ($f[0] eq "S") { $sections++; $insns += $f[3]; $ticks += $f[4]; }
        elsif ($f[0] eq "U") { $unknown{$f[1]} += $f[2]; }
        elsif ($f[0] eq "P") {
            my (undef, $name, $asm, $label, $kind, $det) = @f;
            push @fail, sprintf("%s %s: %s", $label, $kind, $det);
        }
    }
    close $fh;
}

my $note_ok = 1;
if (defined $so) {
    # the note: namesz 3, descsz 4, type 1, "rr\0", desc = the ABI version (1)
    my $hex = "";
    open(my $fh, "-|", $OBJDUMP, "-s", "-j", ".note.rrsoftticks", $so) or die "$OBJDUMP: $!\n";
    while (<$fh>) { $hex .= join "", /^ [0-9a-f]+ ((?:[0-9a-f]{2,8} ){1,4})/ ? split(' ', $1) : (); }
    close $fh;
    $note_ok = $hex =~ /^0300000004000000010000007272000001000000/;
    push @fail, "$so: no software ticks note of ABI version 1" unless $note_ok;
    # the initializer (hidden, so only in .symtab, which the library has until it is stripped)
    my $init = 0;
    open($fh, "-|", $OBJDUMP, "-t", $so) or die "$OBJDUMP: $!\n";
    while (<$fh>) { $init = 1 if /\s__rr_softticks_init$/; }
    close $fh;
    push @fail, "$so: no software ticks initializer (__rr_softticks_init)" unless $init;
}

printf "softticks check: %d objects (%d assembled, %d compiled), %d sections, %d instructions, %d ticks\n",
    ($nobj{asm} // 0) + ($nobj{c} // 0), $nobj{asm} // 0, $nobj{c} // 0, $sections, $insns, $ticks;
printf "unknown mnemonics (taken to read all flags): %s\n",
    join(" ", map { "$_($unknown{$_})" } sort keys %unknown) if %unknown;
if (@fail) {
    printf "%d findings:\n", scalar @fail;
    print "  $_\n" for @fail;
    exit 1;
}
print "no findings\n";
exit 0;
