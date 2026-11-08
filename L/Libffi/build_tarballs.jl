using BinaryBuilder

name = "Libffi"
upstream_version = "3.5.2"
version = VersionNumber(upstream_version)

# Collection of sources required to build libffi
sources = [
    ArchiveSource("https://github.com/libffi/libffi/releases/download/v$(upstream_version)/libffi-$(upstream_version).tar.gz",
                  "f3a3082a23b37c293a4fcd1053147b371f2ff91fa7ea1b2a52e335676bac82dc"),
    DirectorySource("./bundled"),
    # rr_softticks (ygglet): the binary tick check, OpenBLAS's (run at the end of the script)
    DirectorySource(joinpath(@__DIR__, "..", "..", "O", "OpenBLAS", "softticks"); target="softticks"),
]

# Bash recipe for building across all platforms
script = raw"""
cd $WORKSPACE/srcdir/libffi-*/
# rr software ticks (rr_softticks platforms): the compiler pass ticks the C code; the patch
# ticks the x86-64 assembly at its entry points. It only acts where the compiler predefines
# __RR_SOFTTICKS__; elsewhere the objects are byte-identical.
atomic_patch -p1 ${WORKSPACE}/srcdir/patches/rr-softticks-x86-64.patch
update_configure_scripts
./configure --prefix=${prefix} \
    --build=${MACHTYPE} \
    --host=${target} \
    --disable-static \
    --enable-shared \
    --disable-multi-os-directory
make -j${nproc}
make install

# rr_softticks: the binary tick check of every object of the library (no cycle and no entry
# point of the assembly without a tick, no flag live after one; softticks.allow has the
# trampolines and the jump tables) and of the library's note and initializer; and every entry
# point of the assembly must begin with the tick, which the check would not notice for
# symbols that are not typed as functions. Only the x86-64 assembly has ticks.
if [[ "${bb_full_target}" == *rr_softticks* ]]; then
    if [[ "${target}" != x86_64-* ]]; then
        echo "Libffi: only the x86-64 assembly has software ticks, not ${target}'s" >&2
        exit 1
    fi
    cd $(dirname */libffi.la)
    perl ${WORKSPACE}/srcdir/softticks/check.pl --selftest
    perl ${WORKSPACE}/srcdir/softticks/check.pl --jobs ${nproc} --so ${libdir}/libffi.so \
        --allow ${WORKSPACE}/srcdir/softticks.allow src/.libs/*.o src/x86/.libs/*.o
    # rr's x86-64 tick of ABI version 1, byte for byte; endbr64 may come first
    tick="f6 04 25 07 18 00 70 80 75 0b 48 ff 0c 25 00 18 00 70 75 01 cc"
    for spec in unix64:7 win64:4; do
        o=src/x86/.libs/${spec%:*}.o
        text=$(${OBJDUMP:-objdump} -h ${o} | awk '$2 == ".text" { print $6 }')
        n=0
        while read -r value type sym; do
            [[ ${type} == T && ${sym} != trampoline_code_table ]] || continue
            bytes=$(od -An -tx1 -v -j $((16#${text} + 16#${value})) -N 25 ${o} | xargs)
            if [[ "${bytes#f3 0f 1e fa }" != "${tick}"* ]]; then
                echo "Libffi: ${sym} (${o}) does not begin with the software tick" >&2
                exit 1
            fi
            n=$((n + 1))
        done < <(${NM:-nm} -g --defined-only ${o})
        if [[ ${n} != ${spec#*:} ]]; then
            echo "Libffi: ${o} has ${n} entry points with the software tick, not ${spec#*:}" >&2
            exit 1
        fi
    done
fi
"""

# These are the platforms we will build for by default, unless further
# platforms are passed in on the command line
platforms = supported_platforms()

# The products that we will ensure are always built
products = [
    LibraryProduct("libffi", :libffi)
]

# Dependencies that must be installed before this package can be built
dependencies = Dependency[
]

# Build the tarballs, and possibly a `build.jl` as well.
build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies; julia_compat="1.6", preferred_gcc_version=v"6")
