# Note that this script can accept some limited command-line arguments, run
# `julia build_tarballs.jl --help` to see a usage message.
using BinaryBuilder, Pkg

name = "less"
version = v"679.0.0"

# Collection of sources required to complete build
sources = [
    DirectorySource("./bundled"),
    # ygglet (BinaryBuilder2): the release tarball of the same version, which has the files
    # `make -f Makefile.aut distfiles` generates (that needs groff, and BB2's Debian rootfs
    # has no `apk`).
    ArchiveSource("https://www.greenwoodsoftware.com/less/less-$(version.major).tar.gz",
                  "9b68820c34fa8a0af6b0e01b74f0298bcdd40a0489c61649b47058908a153d78"),
]

# Bash recipe for building across all platforms
script = raw"""
cd $WORKSPACE/srcdir/less*/
for f in ${WORKSPACE}/srcdir/patches/*.patch; do
    atomic_patch -p1 ${f}
done
autoreconf --install
./configure --prefix=${prefix} --build=${MACHTYPE} --host=${target}
if [[ ${COMPILER_TARGET} == *-mingw* ]]; then
echo "#define MSDOS_COMPILER WIN32C" >> defines.h
fi
make -j20 install
"""

# These are the platforms we will build for by default, unless further
# platforms are passed in on the command line
platforms = supported_platforms()

# The products that we will ensure are always built
products = [
    ExecutableProduct("lessecho", :lessecho),
    ExecutableProduct("lesskey", :lesskey),
    ExecutableProduct("less", :less)
]

# Dependencies that must be installed before this package can be built
dependencies = [
    Dependency(PackageSpec(name="Ncurses_jll"))
]

# Build the tarballs, and possibly a `build.jl` as well.
build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies; julia_compat="1.6")
