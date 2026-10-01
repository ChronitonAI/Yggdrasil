# Note that this script can accept some limited command-line arguments, run
# `julia build_tarballs.jl --help` to see a usage message.
using BinaryBuilder, Pkg

name = "Bash"
version = v"5.2.37"

sources = [
    ArchiveSource("https://ftp.gnu.org/gnu/bash/bash-$(version).tar.gz",
                  "9599b22ecd1d5787ad7d3b7bf0c59f312b3396d1e281175dd1f8a4014da621ff"),
]

script = raw"""
cd $WORKSPACE/srcdir/bash-*
# Bash's own readline and its termcap replacement: no dependencies beyond libc.
./configure --prefix=${prefix} --build=${MACHTYPE} --host=${target} \
    --without-bash-malloc \
    --with-installed-readline=no \
    --disable-nls
make -j${nproc}
make install
ln -sf bash ${bindir}/sh
install_license COPYING
"""

platforms = supported_platforms(; exclude=p -> !Sys.islinux(p))

products = [
    ExecutableProduct("bash", :bash),
]

dependencies = Dependency[]

build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies; julia_compat="1.6")
