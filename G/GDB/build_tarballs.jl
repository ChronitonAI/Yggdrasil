# Note that this script can accept some limited command-line arguments, run
# `julia build_tarballs.jl --help` to see a usage message.
using BinaryBuilder, Pkg

name = "GDB"
version_string = "12.1"
version = v"12.1.1" # Different from VersionNumber(version_string) because we changed the dependencies

# Collection of sources required to complete build
sources = [
    ArchiveSource("https://ftp.gnu.org/gnu/gdb/gdb-$(version_string).tar.xz",
                  "0e1793bf8f2b54d53f46dea84ccfd446f48f81b297b28c4f7fc017b818d69fed"),
    DirectorySource("./bundled")
]

# Bash recipe for building across all platforms
script = raw"""
apk add texinfo

cd $WORKSPACE/srcdir/gdb-*/
install_license COPYING

CONFIGURE_FLAGS=(--prefix=${prefix} --build=${MACHTYPE} --host=${target})
CONFIGURE_FLAGS+=(--with-expat)
CONFIGURE_FLAGS+=(--with-system-zlib)   # to avoid linking against libcrypt.so.1
if [[ ${target} != *mingw* ]]; then
    # Python_jll is not yet available for Windows
    CONFIGURE_FLAGS+=(--with-python=${WORKSPACE}/srcdir/python-cross-configure.sh)
fi
./configure ${CONFIGURE_FLAGS[@]}

make -j${nproc} all
make install
"""

# ygglet (BinaryBuilder2, rr_softticks platforms, x86_64 Linux only): GDB 16.3 (rr's test
# suite drives a recent gdb; 12.1 predates Python 3.12), a native build (build and host are
# both x86_64 Linux) configured with the target's own Python 3.12, which runs here with
# our libraries on LD_LIBRARY_PATH, instead of the spoofed python-config. The Python home
# lies under the prefix, so gdb relocates it (to /usr in the image). No docs (`makeinfo`),
# NLS or simulators. (The top-level configure takes --with-gmp/--with-mpfr as paths: a bare
# `--with-mpfr` links against `yes/lib`.)
const ygglet = any(contains("rr_softticks"), ARGS)
if ygglet
    version_string = "16.3"
    version = v"16.3"
    sources = [
        ArchiveSource("https://ftp.gnu.org/gnu/gdb/gdb-$(version_string).tar.xz",
                      "bcfcd095528a987917acf9fff3f1672181694926cc18d609c99d0042c00224c5"),
    ]
    script = raw"""
cd $WORKSPACE/srcdir/gdb-*/
install_license COPYING
export LD_LIBRARY_PATH="${libdir}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export CPPFLAGS="${CPPFLAGS} -I${includedir}"
export LDFLAGS="${LDFLAGS} -L${libdir}"
mkdir build && cd build
../configure --prefix=${prefix} --build=${MACHTYPE} --host=${target} \
    --with-expat --with-libexpat-prefix=${prefix} \
    --with-system-zlib \
    --with-gmp=${prefix} --with-libgmp-prefix=${prefix} \
    --with-mpfr=${prefix} --with-libmpfr-prefix=${prefix} \
    --with-python=${bindir}/python3 \
    --disable-nls \
    --disable-sim \
    --disable-werror \
    MAKEINFO=true
make -j${nproc} all MAKEINFO=true
# Only gdb and gdbserver: a plain `make install` also installs the bfd, opcodes and ctf
# libraries and headers, which are Binutils_jll's.
make install-gdb install-gdbserver MAKEINFO=true
${bindir}/gdb --batch -ex 'python import sys; print(sys.version)'
"""
end

# These are the platforms we will build for by default, unless further
# platforms are passed in on the command line
platforms = [
    Platform("i686", "linux"; libc = "glibc"),
    Platform("x86_64", "linux"; libc = "glibc"),
    Platform("aarch64", "linux"; libc = "glibc"),
    Platform("armv7l", "linux"; call_abi = "eabihf", libc = "glibc"),
    Platform("armv7l", "linux"; call_abi = "eabihf", libc = "musl"),
    Platform("i686", "windows"; ),
    Platform("x86_64", "windows"; )
]
platforms = expand_cxxstring_abis(platforms)

# The products that we will ensure are always built
products = [
    ExecutableProduct("gdbserver", :gdbserver),
    ExecutableProduct("gdb", :gdb)
]

# Dependencies that must be installed before this package can be built
dependencies = [
    Dependency(PackageSpec(name="GMP_jll", uuid="781609d7-10c4-51f6-84f2-b8444358ff6d"); compat="6.2.0"),
    Dependency("Expat_jll"; compat="2.2.10"),
    Dependency("Python_jll"; compat="~3.10.14"),
    Dependency("Zlib_jll")
]
if ygglet
    dependencies = [
        Dependency("GMP_jll"),
        Dependency("MPFR_jll"),
        Dependency("Expat_jll"),
        Dependency("Python_jll"; compat="3.12"),
        Dependency("Ncurses_jll"),
        Dependency("Zlib_jll"),
        # configure finds liblzma (in the prefix for Python) and links it, for MiniDebugInfo
        Dependency("XZ_jll"),
        # gdb is C++: libstdc++ and libgcc_s.
        Dependency("CompilerSupportLibraries_jll"),
    ]
end

# Build the tarballs, and possibly a `build.jl` as well.
build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies;
               julia_compat="1.6", preferred_gcc_version = v"11.1.0")
