# Glibc 2.17 as BinaryBuilder2's C toolchain installs it in its sysroot (the oldest glibc
# ABI on x86_64), for a platform BinaryBuilder2 has no build of it for yet, such as ygglet's
# rr software ticks platform (`x86_64-linux-gnu-rr_softticks+1`). Built like BinaryBuilder2's
# own bootstrap (`bootstrap/Glibc`): with the bootstrap compiler, which needs no glibc for
# the target. On a software ticks platform that compiler loads the software ticks plugin
# (GCCBootstrapSoftTicksPlugin), and the static `_start` and the dynamic loader map the
# countdown page first thing (as ygglet's Glibc 2.41 does), since crt1.o is linked into
# every program built against this sysroot.
#
# Build it into the toolchain universe, not into one whose Glibc_jll is a different version:
#   YGGLET_UNIVERSE=ygglet-toolchain scripts/bb2-build G/Glibc/Glibc@2.17-toolchain
using BinaryBuilder2

version = v"2.17"

script = raw"""
cd ${WORKSPACE}/srcdir/glibc-*/
install_license COPYING*

for p in ${WORKSPACE}/srcdir/patches/glibc-*.patch; do
    atomic_patch -p1 ${p}
done
if [[ "${bb_full_target}" == *rr_softticks* ]]; then
    atomic_patch -p1 ${WORKSPACE}/srcdir/patches_softticks/glibc-200-rr-softticks-countdown-page.patch
fi

# Various configure overrides (as in BinaryBuilder2's bootstrap/Glibc)
GLIBC_CONFIGURE_OVERRIDES=( libc_cv_forced_unwind=yes libc_cv_c_cleanup=yes BUILD_CC=${HOSTCC} )
GLIBC_CONFIGURE_OVERRIDES+=( libc_cv_slibdir=/lib libdir="/lib" )
GLIBC_CONFIGURE_OVERRIDES+=( CFLAGS="-g -O2 -fcommon -Wno-implicit-int -Wno-implicit-function-declaration -Wno-builtin-declaration-mismatch -Wno-array-parameter -Wno-int-conversion" )

mkdir -p ${WORKSPACE}/srcdir/glibc_build
cd ${WORKSPACE}/srcdir/glibc_build
${WORKSPACE}/srcdir/glibc-*/configure \
    --prefix=/usr \
    --build=${MACHTYPE} \
    --host=${target} \
    --disable-multilib \
    --disable-werror \
    "${GLIBC_CONFIGURE_OVERRIDES[@]}"

make -j${nproc}
make install install_root="${prefix}"

# Copy our `crt*.o` files over (useful for bootstrapping GCC)
csu_libdir="${prefix}/lib"
cp csu/crt1.o csu/crti.o csu/crtn.o ${csu_libdir}/

# fix bad linker scripts
sed -i -e "s& /lib/& ./&g" "${csu_libdir}/libc.so"
sed -i -e "s& /lib/& ./&g" "${csu_libdir}/libpthread.so"

if [[ -d ${prefix}/${prefix} ]]; then
    mv -v ${prefix}/${prefix}/* ${prefix}/
    rm -rf ${prefix}/workspace
fi
"""

build_tarballs(;
    src_name = "Glibc",
    src_version = version,
    sources = [
        ArchiveSource("https://mirrors.kernel.org/gnu/glibc/glibc-2.17.tar.xz",
                      "6914e337401e0e0ade23694e1b2c52a5f09e4eda3270c67e7c3ba93a89b5b23e"),
        # BinaryBuilder2's bootstrap/Glibc/patches-v2.17.0
        DirectorySource(joinpath(@__DIR__, "bundled", "patches"); target="patches"),
        DirectorySource(joinpath(@__DIR__, "bundled", "patches_softticks"); target="patches_softticks"),
    ],
    script,
    platforms = [Platform("x86_64", "linux"; rr_softticks="1")],
    products = [
        # The dynamic loader, which the other libraries depend on
        LibraryProduct("lib/ld-2.17", :ld),
        LibraryProduct("lib/libc-2.17", :libc),
        LibraryProduct("lib/libdl-2.17", :libdl),
        LibraryProduct("lib/libm-2.17", :libm),
        LibraryProduct("lib/libpthread-2.17", :libpthread),
        LibraryProduct("lib/librt-2.17", :librt),
        LibraryProduct("lib/libresolv-2.17", :libresolv),
        LibraryProduct("lib/libutil-2.17", :libutil),
    ],
    host_toolchains = [CToolchain(; vendor=:bootstrap), HostToolsToolchain()],
    target_toolchains = [CToolchain(; vendor=:bootstrap)],
)
