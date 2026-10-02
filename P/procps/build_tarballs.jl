# Note that this script can accept some limited command-line arguments, run
# `julia build_tarballs.jl --help` to see a usage message.
using BinaryBuilder, Pkg

name = "procps"
version = v"4.0.5"

# Collection of sources required to complete build
sources = [
    DirectorySource("./bundled"),
    # ygglet (BinaryBuilder2): the release tarball of the same version, which has a
    # generated `configure`, so the build needs no `autopoint` (BB2's Debian rootfs has no
    # `apk`). It is unpacked to procps/, where the patches expect it.
    ArchiveSource("https://downloads.sourceforge.net/project/procps-ng/Production/procps-ng-$(version).tar.xz",
                  "c2e6d193cc78f84cd6ddb72aaf6d5c6a9162f0470e5992092057f5ff518562fa"),
]

dependencies = Dependency[
    Dependency("Ncurses_jll")
]

# Bash recipe for building across all platforms
script = raw"""
cd $WORKSPACE/srcdir
mv procps-ng-* procps
for f in ${WORKSPACE}/srcdir/patches/*.patch; do
    if [[ ! -d procps/.git ]]; then
        # (release tarball: drop the patches' hunks for the git checkout's .git/index)
        awk '/^diff --git/ { skip = ($0 ~ /\/\.git\//) } !skip' ${f} > ${f}.src && f=${f}.src
    fi
    atomic_patch -p1 ${f}
done
cd procps/
if ! command -v pkg-config >/dev/null; then
    # BinaryBuilder2's build environment has no pkg-config: pass ncursesw's flags (from its
    # ncursesw.pc) directly; configure only insists that some $PKG_CONFIG exists.
    export PKG_CONFIG=true
    export NCURSES_CFLAGS="-D_GNU_SOURCE -DNCURSES_WIDECHAR -I${includedir}/ncursesw -I${includedir}"
    export NCURSES_LIBS="-L${libdir} -lncursesw"
fi
./configure --prefix=${prefix} --build=${MACHTYPE} --host=${target} --disable-pidwait LDFLAGS="-lrt"
make -j${nproc} install
"""

# Depends on qsort_r for which our musl version is too old
platforms = filter!(p -> Sys.islinux(p) && p["libc"] != "musl", supported_platforms())

# The products that we will ensure are always built
products = Product[
    ExecutableProduct("pidof", :pidof),
    ExecutableProduct("watch", :watch),
    ExecutableProduct("pmap", :pmap),
    ExecutableProduct("top", :top),
    ExecutableProduct("ps", :ps),
    LibraryProduct("libproc2", :libproc2),
    ExecutableProduct("free", :free),
    ExecutableProduct("pgrep", :pgrep),
    ExecutableProduct("pkill", :pkill),
    ExecutableProduct("uptime", :uptime),
    ExecutableProduct("hugetop", :hugetop),
    ExecutableProduct("slabtop", :slabtop),
    ExecutableProduct("tload", :tload),
    ExecutableProduct("pwdx", :pwdx),
    ExecutableProduct("w", :w),
    ExecutableProduct("sysctl", :sysctl, "sbin"),
    ExecutableProduct("vmstat", :vmstat),
    ExecutableProduct("kill", :pskill)
]

# Build the tarballs, and possibly a `build.jl` as well.
build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies; julia_compat="1.6")
