using BinaryBuilder, Pkg
using BinaryBuilderBase: sanitize

name = "LibUnwind"
version = v"1.8.3"

# Collection of sources required to build libunwind
sources = [
    ArchiveSource("https://github.com/libunwind/libunwind/releases/download/v$(version)/libunwind-$(version).tar.gz",
                  "be30d910e67f58d82e753231f1357f326a1a088acf126b21ff77e60aab19b90b"),
    DirectorySource("./bundled"),
]

# Bash recipe for building across all platforms
script = raw"""
cd $WORKSPACE/srcdir/libunwind*/

atomic_patch -p0 ${WORKSPACE}/srcdir/patches/libunwind-configure-static-lzma.patch
if [[ ${target} == aarch64-linux-musl ]]; then
    # https://github.com/checkpoint-restore/criu/issues/934, fixed by
    # https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit?id=9966a05c7b80f075f2bc7e48dbb108d3f2927234
    pushd /opt/aarch64-linux-musl/aarch64-linux-musl/sys-root/usr/include
    atomic_patch -p5 ${WORKSPACE}/srcdir/patches/linux-disentangle_sigcontext.patch
    popd
fi
# https://github.com/JuliaLang/julia/issues/51467, and
# https://github.com/JuliaLang/julia/issues/51465, caused by
# https://github.com/libunwind/libunwind/pull/203
atomic_patch -p1 ${WORKSPACE}/srcdir/patches/libunwind-revert_prelink_unwind.patch

atomic_patch -p1 ${WORKSPACE}/srcdir/patches/libunwind-disable-initial-exec-tls.patch

# rr software ticks for the x86-64 assembly (getcontext.S, setcontext.S, longjmp.S,
# siglongjmp.S): a tick at each function's entry, which the compiler's ticks plugin cannot
# add to assembly. Only where the compiler predefines __RR_SOFTTICKS__ (the plugin, on the
# rr_softticks platforms); elsewhere the objects are byte-identical. The static liblzma
# linked in below comes from XZ_jll, whose own patch ticks its one inline-asm loop.
atomic_patch -p1 ${WORKSPACE}/srcdir/patches/libunwind-rr-softticks.patch

if [[ ${bb_full_target} == *-sanitize+memory* ]]; then
    # Install msan runtime (for clang)
    cp -rL ${libdir}/linux/* /opt/x86_64-linux-musl/lib/clang/*/lib/linux/
fi

export CFLAGS="-O2 -DPI -fPIC"
# liblzma is linked statically, don't re-export its symbols
export LDFLAGS="-Wl,--exclude-libs=liblzma.a"
if [[ "${target}" == aarch64-linux-* ]]; then
    # Define macro introduced in later Linux kernel than what we have in the RootFS.
    CFLAGS="${CFLAGS} -DNT_ARM_PAC_MASK=0x406"
fi
./configure \
    --prefix=${prefix} \
    --build=${MACHTYPE} \
    --host=${target} \
    --libdir=${libdir} \
    --enable-debug_frame \
    --enable-minidebuginfo \
    --enable-zlibdebuginfo \
    --disable-tests \
    --disable-conservative-checks \
    --enable-per-thread-cache
make -j${nproc}
make install

# rr_softticks: fail the build if the software ticks did not land, which it would not notice
# otherwise (the patch is a no-op without __RR_SOFTTICKS__, a hunk can apply in the wrong
# place after a version bump, and XZ_jll may predate XZ's own patch): every x86-64 .S
# object must carry its entry ticks, and the asm loop of liblzma's rc_direct(), linked into
# libunwind.so from XZ_jll's static liblzma, must tick. Only x86-64's assembly has ticks.
if [[ "${bb_full_target}" == *rr_softticks* ]]; then
    if [[ "${target}" != x86_64-* ]]; then
        echo "LibUnwind: only the x86-64 assembly has software ticks, not ${target}'s" >&2
        exit 1
    fi
    # The software ticks (rr's x86-64 sequence of ABI version 1: testb $0x80,0x70001807;
    # jne; decq 0x70001800; jne; int3) in an object's code
    count_ticks() {
        local d
        d=$(${OBJDUMP:-objdump} -d --no-show-raw-insn "$1") || return 1
        awk '{ sub(/^ *[0-9a-f]+:[ \t]+/, ""); gsub(/[ \t]+/, " "); gsub(/, /, ","); sub(/ $/, "") }
             /^testb \$-?0x80,0x70001807$/ { s = 1; next }
             s == 1 && /^jne / { s = 2; next }
             s == 2 && /^decq 0x70001800$/ { s = 3; next }
             s == 3 && /^jne / { s = 4; next }
             s == 4 && /^int3$/ { n++ }
             { s = 0 }
             END { print n + 0 }' <<< "${d}"
    }
    # rc_direct()'s asm loops in a file, as "LOOPS TICKED": a jne back to the loop head right
    # after the asm's fixed tail (shr, mov, sub, cmov, cmov, dec); TICKED counts the loops
    # with a tick between their head and that jne.
    rc_direct_loops() {
        local d
        d=$(${OBJDUMP:-objdump} -d --no-show-raw-insn "$1") || return 1
        awk '/^ *[0-9a-f]+:[ \t]/ {
                 a = $1; sub(/:$/, "", a); i = $2; t = $3; sub(/^0x/, "", t)
                 n++; addr[n] = a
                 tick[n] = (i == "testb" && $0 ~ /\$-?0x80, ?0x70001807 *$/)
                 m[n] = (i ~ /^cmov/ ? "cmov" : i ~ /^(shr|mov|sub|dec)/ ? substr(i, 1, 3) : i)
                 if (i == "jne" && n > 6 && m[n-6] == "shr" && m[n-5] == "mov" && m[n-4] == "sub" &&
                     m[n-3] == "cmov" && m[n-2] == "cmov" && m[n-1] == "dec") {
                     for (j = n - 1; j > 0 && addr[j] != t; j--) {}
                     if (j > 0) { loops++; for (; j < n; j++) if (tick[j]) { ticked++; break } }
                 }
                 next
             }
             { m[n] = "" }
             END { print loops + 0, ticked + 0 }' <<< "${d}"
    }
    # getcontext.S: _Ux86_64_getcontext and _Ux86_64_getcontext_trace; the others one function
    for spec in getcontext:2 setcontext:1 longjmp:1 siglongjmp:1; do
        found=0
        for o in src/x86_64/${spec%:*}.o src/x86_64/.libs/${spec%:*}.o; do
            [[ -f "${o}" ]] || continue
            found=1
            n=$(count_ticks "${o}") || exit 1
            if [[ "${n}" != "${spec#*:}" ]]; then
                echo "LibUnwind: ${o} has ${n} software ticks, not ${spec#*:}" >&2
                exit 1
            fi
        done
        if (( ! found )); then
            echo "LibUnwind: no object of src/x86_64/${spec%:*}.S" >&2
            exit 1
        fi
    done
    r=$(rc_direct_loops ${libdir}/libunwind.so) || exit 1
    read -r loops ticked <<< "${r}"
    if (( loops == 0 || ticked != loops )); then
        echo "LibUnwind: ${ticked} of the ${loops} rc_direct() asm loops in libunwind.so tick" \
             "(XZ_jll's liblzma.a must be built with XZ's software ticks patch)" >&2
        exit 1
    fi
fi

# Shoe-horn liblzma.a into libunwind.a
mkdir -p unpacked/{liblzma,libunwind}
(cd unpacked/liblzma; ar -x ${prefix}/lib/liblzma.a)
(cd unpacked/libunwind; ar -x ${prefix}/lib/libunwind.a)
rm -f ${prefix}/lib/libunwind.a
ar -qc ${prefix}/lib/libunwind.a unpacked/**/*
"""

# These are the platforms we will build for by default, unless further
# platforms are passed in on the command line.  libunwind is only used
# on Linux or FreeBSD (e.g. ELF systems)
platforms = filter(p -> Sys.islinux(p) || Sys.isfreebsd(p), supported_platforms())
push!(platforms, Platform("x86_64", "linux"; sanitize="memory"))

# The products that we will ensure are always built
products = [
    LibraryProduct("libunwind", :libunwind),
]

llvm_version = v"13.0.1"

# Dependencies that must be installed before this package can be built
dependencies = [
    Dependency("Zlib_jll"),
    # ygglet (BinaryBuilder2, rr_softticks platforms): the static liblzma comes from the
    # universe's own XZ_jll, whatever its version (a pinned version the universe does not
    # have makes BinaryBuilder2 resolve all of the dependencies from upstream instead).
    if any(contains("rr_softticks"), ARGS)
        BuildDependency("XZ_jll")
    else
        BuildDependency(PackageSpec(name="XZ_jll",
                                    uuid="ffd25f8a-64ca-5728-b0f7-c24cf3aae800",
                                    version="5.8.1"))
    end,
    BuildDependency(PackageSpec(name="LLVMCompilerRT_jll",
                                uuid="4e17d02c-6bf5-513e-be62-445f41c75a11",
                                version=string(llvm_version));
                    platforms=filter(p -> sanitize(p) == "memory", platforms)),
]

# Build the tarballs. Note that libunwind started using `stdatomic.h`, which is only
# available with GCC version 4.9 or later, so we need to set a higher preferred version
# than the default.
build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies;
               julia_compat="1.10", preferred_gcc_version=v"11",
               preferred_llvm_version=llvm_version)
