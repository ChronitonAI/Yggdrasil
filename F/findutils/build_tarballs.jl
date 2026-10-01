# Note that this script can accept some limited command-line arguments, run
# `julia build_tarballs.jl --help` to see a usage message.
using BinaryBuilder, Pkg

name = "findutils"
version = v"4.10.0"

sources = [
    ArchiveSource("https://ftp.gnu.org/gnu/findutils/findutils-$(version).tar.xz",
                  "1387e0b67ff247d2abde998f90dfbf70c1491391a59ddfecb8ae698789f0a4f5"),
]

script = raw"""
cd $WORKSPACE/srcdir/findutils-*
./configure --prefix=${prefix} --build=${MACHTYPE} --host=${target} --disable-nls
make -j${nproc}
make install
install_license COPYING
"""

platforms = supported_platforms(; exclude=p -> !Sys.islinux(p))

products = [
    ExecutableProduct("find", :find),
    ExecutableProduct("xargs", :xargs),
]

dependencies = Dependency[]

build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies; julia_compat="1.6")
