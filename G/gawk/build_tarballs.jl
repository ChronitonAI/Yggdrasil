using BinaryBuilder

name = "gawk"
version = v"5.4.1"

# Collection of sources required to complete build
sources = [
    # ygglet (BinaryBuilder2): the release tarball of the same version, which has the
    # generated docs, so the build needs no `makeinfo` (`apk add texinfo` does not work on
    # BB2's Debian rootfs).
    ArchiveSource("https://ftp.gnu.org/gnu/gawk/gawk-$(version).tar.xz",
                  "07f6f7342b7febe4313fc2c2542ad93d64fe20ad8717200109f105a826f5fd37"),
    DirectorySource("bundled"),
]

# Bash recipe for building across all platforms
script = raw"""
cd $WORKSPACE/srcdir/gawk*/

# Add missing #include for `_NSGetExecutablePath`
atomic_patch -p1 $WORKSPACE/srcdir/patches/gawk_nsgep.patch

# Apply workaround for v5.4.1 layout bug
# (see https://lists.gnu.org/archive/html/bug-gawk/2026-07/msg00020.html)
atomic_patch -p1 $WORKSPACE/srcdir/patches/gawk_node_alignment.patch


CONFIGURE_ARGS=()
if [[ ${target} == aarch64-apple-darwin* ]]; then
    # See https://git.savannah.gnu.org/cgit/gawk.git/tree/README_d/README.macosx?h=gawk-5.2.1#n1
    CONFIGURE_ARGS+=( --disable-pma )
fi

./configure --prefix=${prefix} --host=${target} ${CONFIGURE_ARGS[@]}
make -j${nproc}
make install
install_license COPYING
"""

# Windows currently fails due to a problem with mingw headers (langinfo.h) not being found
platforms = filter(!Sys.iswindows, supported_platforms())
products = [
    ExecutableProduct("gawk", :gawk)
]
dependencies = Dependency[]
build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies; julia_compat="1.6")
