# Note that this script can accept some limited command-line arguments, run
# `julia build_tarballs.jl --help` to see a usage message.
using BinaryBuilder, Pkg

name = "which"
version = v"2.21"

sources = [
    ArchiveSource("https://ftp.gnu.org/gnu/which/which-$(version.major).$(version.minor).tar.gz",
                  "f4a245b94124b377d8b49646bf421f9155d36aa7614b6ebf83705d3ffc76eaad"),
]

script = raw"""
cd $WORKSPACE/srcdir/which-*
./configure --prefix=${prefix} --build=${MACHTYPE} --host=${target}
make -j${nproc}
make install
install_license COPYING
"""

platforms = supported_platforms(; exclude=p -> !Sys.islinux(p))

products = [
    ExecutableProduct("which", :which),
]

dependencies = Dependency[]

build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies; julia_compat="1.6")
