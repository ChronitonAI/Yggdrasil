# Note that this script can accept some limited command-line arguments, run
# `julia build_tarballs.jl --help` to see a usage message.
using BinaryBuilder

name = "Python"
version = v"3.12.14"

# Collection of sources required to build Python
sources = [
    ArchiveSource("https://www.python.org/ftp/python/$(version)/$(name)-$(version).tar.xz",
                  "5c8462af5790baf43a321a1559dbe0db06d1be4300fb85fb53c40060668e548a"),
    # Deliberately an installer from the same 24.3.0 generation as the py311 one
    # this replaced: Miniconda installers from 24.11 onwards gate on
    # `ldd --version` reporting GLIBC >= 2.28, which fails outright in
    # BinaryBuilder's musl sandbox ("Installer requires GLIBC >=2.28, but system
    # has ."). Do not casually bump this to the newest available.
    FileSource("https://repo.anaconda.com/miniconda/Miniconda3-py312_24.3.0-0-Linux-x86_64.sh",
                "96a44849ff17e960eeb8877ecd9055246381c4d4f2d031263b63fa7e2e930af1", "miniconda.sh"),
    DirectorySource("./bundled"),
]

# Bash recipe for building across all platforms
script = raw"""
# Python's autoconf scripts use non-default macros
apk add autoconf-archive

# Having a global `python3` screws things up a bit, so get rid of that
rm -f $(which python3)

# Install miniconda to get the build python necessary for cross-compilation
# (--with-build-python must be at least the version being built).
cd ${WORKSPACE}/srcdir
bash miniconda.sh -b -p ${host_bindir}/miniconda


# We need these for the host python build
apk update
apk add zlib-dev libffi-dev

# Create fake `arch` command:
echo '#!/bin/bash' >> /usr/bin/arch
if [[ "${target}" == *-apple-* ]]; then
    echo 'echo i386'  >> /usr/bin/arch
else
    echo 'echo `echo $target | cut -d - -f 1`'  >> /usr/bin/arch
fi
chmod +x /usr/bin/arch

# Patch out cross compile limitations
cd ${WORKSPACE}/srcdir/Python-*/
atomic_patch -p1 ${WORKSPACE}/srcdir/patches/cross_compile_configure_ac.patch

# Disable detection of multiarch as it breaks with clang >= 13, which adds a
# major.minor version number in -print-multiarch output, confusing Python.
# https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=258377
if [[ "${target}" == *-freebsd* || ${target} == *darwin* ]]; then
    sed -i 's|^MULTIARCH=.*|MULTIARCH=|' configure.ac
fi

autoreconf -i

# Next, build host version
mkdir build_host && cd build_host

# Override `bb_target`, `CC`, etc... to give this `./configure` the impression
# that we are actually targeting `${MACHTYPE}` and not `${target}`
# Confine pkg-config to the rootfs: ${prefix}/lib/pkgconfig has the *target's*
# bzip2.pc/liblzma.pc, and PKG_CHECK_MODULES feeds their -L flags to the host
# compiler ("cannot find -lbz2").  3.11 skipped such modules via setup.py; 3.12
# builds them from configure-generated Makefile rules, so the build fails.
bb_target=${MACHTYPE} CC=${HOSTCC} CPPFLAGS=-I/usr/include LDFLAGS="-L/lib -L/usr/lib" \
    PKG_CONFIG_PATH="" PKG_CONFIG_LIBDIR="/usr/lib/pkgconfig:/usr/share/pkgconfig" \
    PKG_CONFIG_SYSROOT_DIR="" \
    ../configure --host="${MACHTYPE}" --build="${MACHTYPE}"
make -j${nproc} python sharedmods

# Next, build target version
cd ${WORKSPACE}/srcdir/Python-*/
mkdir build_target && cd build_target

export CPPFLAGS="${CPPFLAGS} -I${prefix}/include"
export LDFLAGS="${LDFLAGS} -L${prefix}/lib -L${prefix}/lib64"
export PATH=$(echo ${WORKSPACE}/srcdir/Python-*/build_host):$PATH

conf_args=()
conf_args+=(--with-build-python=${host_bindir}/miniconda/bin/python)
conf_args+=(--enable-shared)
conf_args+=(--disable-ipv6)
conf_args+=(--with-ensurepip=no)
conf_args+=(--disable-test-modules)
conf_args+=(--with-system-expat)
conf_args+=(--with-system-ffi)
# Not --with-system-libmpdec: CPython 3.12 sets libmpdec_machine=universal on
# Darwin (configure.ac), so LIBMPDEC_CFLAGS gets -DUNIVERSAL instead of
# -DCONFIG_64, and _decimal.c then fails with "No valid combination of
# CONFIG_64, CONFIG_32 and _PyHASH_BITS" -- that path only works with the
# bundled libmpdec.  3.11 hid this by skipping unbuildable modules in setup.py,
# which is why the registered 3.11.12 ships no _decimal on Darwin or riscv64.
# Python 3.12 still bundles libmpdec, so use it and drop LibMPDec_jll.
# NOTE: the bundled copy is gone in 3.13; revisit at the next bump.
conf_args+=(--enable-optimizations)
conf_args+=(ac_cv_file__dev_ptmx=no)
conf_args+=(ac_cv_file__dev_ptc=no)
conf_args+=(ac_cv_have_chflags=no)

../configure --prefix="${prefix}" --host="${target}" --build="${MACHTYPE}" "${conf_args[@]}"

make -j${nproc}
make install

install_license ${WORKSPACE}/srcdir/Python-*/LICENSE
"""

# ygglet (BinaryBuilder2, rr_softticks platforms, x86_64 Linux only): a native build. The
# build machine runs x86_64 Linux code too, so `configure` is not cross compiling and the
# build runs its own (instrumented) `python` instead of a miniconda one; BB2's Debian rootfs
# has no `apk`, and nothing is cross compiled, so neither the configure.ac patch nor
# autoreconf is needed. No PGO (`--enable-optimizations`): the profiling run would be the
# test suite. Readline and Ncurses for the `readline` and `curses` modules.
const ygglet = any(contains("rr_softticks"), ARGS)
if ygglet
    sources = [
        sources[1],
        # the software tick of the perf trampoline (bundled/patches/rr-softticks-perf-trampoline.patch)
        DirectorySource("./bundled"),
        # the binary tick check, OpenBLAS's (run at the end of the script)
        DirectorySource(joinpath(@__DIR__, "..", "..", "O", "OpenBLAS", "softticks"); target="softticks"),
    ]
    script = raw"""
cd ${WORKSPACE}/srcdir/Python-*/
# rr software ticks: the compiler's pass ticks the C code; the one assembly function, the x86-64
# perf trampoline (Python/asm_trampoline.S, which perf_trampoline.c copies into the executable
# arenas of `-X perf`/PYTHONPERFSUPPORT, one copy per code object), gets a tick at its entry from
# the patch. The copies tick too: the tick has no relocation and jumps only inside itself. The
# rest has no loop the pass cannot see: libmpdec's x86-64 inline asm is straight-line (mulq,
# divq, bsr, bsf), HACL* and BLAKE2 are C, the bundled expat is not used and ctypes uses the
# system libffi. The patch only acts where the compiler predefines __RR_SOFTTICKS__; elsewhere
# the objects are byte-identical.
atomic_patch -p1 ${WORKSPACE}/srcdir/patches/rr-softticks-perf-trampoline.patch
# The modules' import checks during the build load our dependencies' libraries.
export LD_LIBRARY_PATH="${libdir}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export CPPFLAGS="${CPPFLAGS} -I${includedir} -I${includedir}/ncursesw"
export LDFLAGS="${LDFLAGS} -L${libdir}"
mkdir build_target && cd build_target
../configure --prefix="${prefix}" --build="${MACHTYPE}" --host="${target}" \
    --enable-shared \
    --with-ensurepip=no \
    --disable-test-modules \
    --with-system-expat \
    --with-system-ffi \
    --with-openssl="${prefix}" \
    --with-readline=readline \
    ac_cv_file__dev_ptmx=yes \
    ac_cv_file__dev_ptc=no \
    py_cv_module__crypt=n/a
# (no `_crypt`: the image's glibc 2.41 has no libcrypt; the module is deprecated anyway)
make -j${nproc}
make install
# libpython3.so (the stable ABI library) is linked from libpython3.12.so alone, with no object
# of its own, so it would lack the software ticks note that every ELF in an ygglet image needs:
# relink it with one (empty, compiled with the plugin) object.
echo 'void _ygglet_libpython3_note(void) {}' > note.c
${CC} -shared -fPIC -o ${libdir}/libpython3.so -Wl,-soname,libpython3.so note.c \
    -Wl,--no-as-needed -L${libdir} -lpython3.12
# The modules rr's test harness (pexpect) and the rest of a development container need.
LD_LIBRARY_PATH="${libdir}" ${bindir}/python3 -c "import _ssl, _ctypes, readline, _sqlite3, zlib, lzma, bz2, pty, termios, select, curses, _decimal, pyexpat"
install_license ${WORKSPACE}/srcdir/Python-*/LICENSE

# rr_softticks: fail the build if the trampoline's tick did not land, which nothing would notice
# otherwise (the patch is a no-op without __RR_SOFTTICKS__, and a new version can change the
# trampoline): in the object, in the static library and in libpython3.12.so.1.0,
# [_Py_trampoline_func_start, _Py_trampoline_func_end), the bytes perf_trampoline.c copies,
# must be rr's x86-64 tick (after the endbr64 with -fcf-protection) and then the trampoline. Then
# the binary tick check over the two objects (no cycle without a tick, no flag live after a tick,
# every tick whole; its entry check skips the trampoline, whose symbols have no type) and
# libpython's note and initializer. (Not over the whole archive: that check does not know which
# calls do not return, so a cycle through a call of Py_FatalError and the like is a finding.)
if [[ "${target}" != x86_64-* ]]; then
    echo "Python: only the x86-64 trampoline has a software tick, not ${target}'s" >&2
    exit 1
fi
# trampoline_bytes FILE [-D]: the bytes of [_Py_trampoline_func_start, _Py_trampoline_func_end)
# in FILE, in hex (-D: from the dynamic symbols, for the shared library)
trampoline_bytes() {
    local syms s e
    syms=$(${NM:-nm} ${2:-} "$1") || return 1
    s=$(awk '$3 == "_Py_trampoline_func_start" { print "0x" $1 }' <<< "${syms}")
    e=$(awk '$3 == "_Py_trampoline_func_end" { print "0x" $1 }' <<< "${syms}")
    [[ -n "${s}" && -n "${e}" ]] || return 1
    ${OBJDUMP:-objdump} -d --start-address=${s} --stop-address=${e} "$1" |
        awk -F'\t' '/^ *[0-9a-f]+:\t/ { gsub(/ /, "", $2); printf "%s", $2 } END { print "" }'
}
# rr's x86-64 tick: testb $0x80,0x70001807; jne 1f; decq 0x70001800; jne 1f; int3; 1:
tick=f604250718007080750b48ff0c25001800707501cc
# the trampoline: sub $8,%rsp; call *%rcx; add $8,%rsp; ret
body=4883ec08ffd14883c408c3
archive=(${prefix}/lib/python3.12/config-3.12-*/libpython3.12.a)
if [[ ! -f "${archive[0]}" ]]; then
    echo "Python: no static library ${archive[0]}" >&2
    exit 1
fi
mkdir -p softticks-check
(cd softticks-check && ${AR:-ar} x "${archive[0]}" asm_trampoline.o)
for f in Python/asm_trampoline.o softticks-check/asm_trampoline.o "${libdir}/libpython3.12.so.1.0"; do
    flags=""
    [[ "${f}" == *.so* ]] && flags=-D
    b=$(trampoline_bytes "${f}" ${flags}) || b=""
    if [[ "${b}" != "${tick}${body}" && "${b}" != "f30f1efa${tick}${body}" ]]; then
        echo "Python: the trampoline in ${f} does not tick at its entry: ${b:-no trampoline}" >&2
        exit 1
    fi
done
perl ${WORKSPACE}/srcdir/softticks/check.pl --selftest
perl ${WORKSPACE}/srcdir/softticks/check.pl --so ${libdir}/libpython3.12.so.1.0 \
    Python/asm_trampoline.o softticks-check/asm_trampoline.o
"""
end

# These are the platforms we will build for by default, unless further
# platforms are passed in on the command line
platforms = supported_platforms()

# Disable windows for now, until we can sort through all of these patches
# and choose the ones that we need:
# https://github.com/msys2/MINGW-packages/tree/1e753359d9b55a46d9868c3e4a31ad674bf43596/mingw-w64-python3
filter!(!Sys.iswindows, platforms)

# The products that we will ensure are always built
products = Product[
    ExecutableProduct("python3", :python),
    LibraryProduct("libpython3", :libpython),
]
if ygglet
    # libpython3.so (the stable ABI library) links to libpython3.12, which the auditor wants
    # listed as a product too
    push!(products, LibraryProduct("lib/libpython3.12.so.1.0", :libpython3_12))
end

# Dependencies that must be installed before this package can be built
dependencies = [
    Dependency("Expat_jll"; compat="2.6.5"),
    Dependency("Bzip2_jll"; compat="1.0.9"),
    # ygglet builds Libffi 3.5.
    Dependency("Libffi_jll"; compat=ygglet ? "3.4.7" : "~3.4.7"),
    Dependency("SQLite_jll"),
    Dependency("Zlib_jll"),
    Dependency("XZ_jll"),
    Dependency("OpenSSL_jll"; compat="3.0.16"),
]
if ygglet
    append!(dependencies, [Dependency("Readline_jll"), Dependency("Ncurses_jll")])
end

init_block = raw"""
ENV["PYTHONHOME"] = artifact_dir
"""

# Build the tarballs, and possibly a `build.jl` as well.
# Python 3.12 uses C11 thread-local storage (`_Thread_local` in
# pycore_pystate.h). BinaryBuilder's default GCC 4.8.5 defaults to gnu89 and
# fails with "unknown type name '_Thread_local'"; GCC >= 5 defaults to gnu11.
build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies;
               init_block, julia_compat = "1.6", preferred_gcc_version = v"9")
