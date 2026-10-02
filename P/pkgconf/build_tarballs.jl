# Note that this script can accept some limited command-line arguments, run
# `julia build_tarballs.jl --help` to see a usage message.
using BinaryBuilder, Pkg

name = "pkgconf"
version = v"2.3.0"

sources = [
    ArchiveSource("https://distfiles.ariadne.space/pkgconf/pkgconf-$(version).tar.xz",
                  "3a9080ac51d03615e7c1910a0a2a8df08424892b5f13b0628a204d3fcce0ea8b"),
]

script = raw"""
cd $WORKSPACE/srcdir/pkgconf-*
configure_flags=()
if [[ "${bb_full_target:-${bb_full_default_target:-${target}}}" == *rr_softticks* ]]; then
    # ygglet images: the JLL prefix is the image's /usr.
    configure_flags+=(--with-pkg-config-dir=/usr/lib/pkgconfig:/usr/share/pkgconfig
                      --with-system-libdir=/usr/lib --with-system-includedir=/usr/include)
fi
./configure --prefix=${prefix} --build=${MACHTYPE} --host=${target} --disable-static "${configure_flags[@]}"
make -j${nproc}
make install
# The usual name.
ln -sf pkgconf ${bindir}/pkg-config
install_license COPYING
"""

platforms = supported_platforms(; exclude=p -> !Sys.islinux(p))

products = [
    ExecutableProduct("pkgconf", :pkgconf),
    ExecutableProduct("pkg-config", :pkg_config),
    LibraryProduct("libpkgconf", :libpkgconf),
]

dependencies = Dependency[]

build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies; julia_compat="1.6")
