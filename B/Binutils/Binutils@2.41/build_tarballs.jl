# Binutils for ygglet images: the native assembler, linker and tools of the image's
# compiler (`as`, `ld`, ... in /usr/bin), built for an rr software ticks platform.
using BinaryBuilder2

build_tarballs(;
    src_name = "Binutils",
    src_version = v"2.41",
    sources = [
        ArchiveSource("https://ftp.wayne.edu/gnu/binutils/binutils-2.41.tar.xz",
                      "ae9a5789e23459e59606e6714723f2d3ffc31c03174191ef0d015bdf06007450"),
        DirectorySource("./bundled"; follow_symlinks=true, target="patches"),
    ],
    script = raw"""
    cd ${WORKSPACE}/srcdir/binutils-*/
    for p in ${WORKSPACE}/srcdir/patches/binutils-*.patch; do
        [[ -f "${p}" ]] && atomic_patch -p1 "${p}"
    done
    # Fix "conflicting types for 'libintl_gettextparse'" (bison regenerating plural.c).
    touch intl/plural.c 2>/dev/null || true
    ./configure --prefix=${prefix} \
        --build=${MACHTYPE} \
        --host=${target} \
        --target=${target} \
        --with-sysroot=/ \
        --disable-multilib \
        --disable-werror \
        --enable-new-dtags \
        --enable-deterministic-archives \
        --disable-gprofng \
        --with-system-zlib
    make -j${nproc} MAKEINFO=true
    make install MAKEINFO=true
    # The native tools under their plain names only (/usr/bin/ld, not x86_64-linux-gnu-ld).
    rm -rf ${prefix}/${target}
    install_license COPYING*
    """,
    platforms = [Platform("x86_64", "linux"; rr_softticks="1")],
    products = [
        ExecutableProduct("as", :as),
        ExecutableProduct("ld", :ld),
        ExecutableProduct("ar", :ar),
        ExecutableProduct("objdump", :objdump),
        ExecutableProduct("readelf", :readelf),
    ],
    target_dependencies = [JLLSource("Zlib_jll")],
    host_toolchains = [CToolchain(; vendor=:gcc), HostToolsToolchain()],
    target_toolchains = [CToolchain(; vendor=:gcc)],
)
