# Note that this script can accept some limited command-line arguments, run
# `julia build_tarballs.jl --help` to see a usage message.
using BinaryBuilder

name = "XZ"
version = v"5.8.4"

# Collection of sources required to complete build
sources = [
    # ygglet (BinaryBuilder2): the release tarball, which has a generated `configure`, so
    # the build needs no `autopoint`/`po4a` (BB2's Debian rootfs has no `apk`).
    ArchiveSource("https://github.com/tukaani-project/xz/releases/download/v$(version)/xz-$(version).tar.xz",
                  "4ce24038fd4221e0d13bc1a2de7a4db56e90b92b3bf75321f6c14be73f65de4b"),
    DirectorySource("./bundled"),
    # rr_softticks (ygglet): the binary tick check, OpenBLAS's (run at the end of the script)
    DirectorySource(joinpath(@__DIR__, "..", "..", "O", "OpenBLAS", "softticks"); target="softticks"),
]

# Bash recipe for building across all platforms
script = raw"""
cd $WORKSPACE/srcdir/xz*
install_license COPYING

# rr software ticks (rr_softticks platforms): the compiler pass ticks the C code but not
# the loop in rc_direct()'s x86-64 inline asm, the one cycle without a tick that the binary
# tick check finds in liblzma; the patch ticks it by hand. It only acts where the compiler
# predefines __RR_SOFTTICKS__; elsewhere the objects are byte-identical.
atomic_patch -p1 ${WORKSPACE}/srcdir/patches/rr-softticks-rc_direct.patch


BUILD_FLAGS=(--prefix=${prefix} --build=${MACHTYPE} --host=${target} --with-pic)

# i686 error "configure works but build fails at crc32_x86.S"
# See 5.3 from https://git.tukaani.org/?p=xz.git;a=blob_plain;f=INSTALL;hb=HEAD
if [[ "${target}" == i686-linux-gnu ]]; then
    BUILD_FLAGS+=(--disable-assembler)
fi

if [[ "${target}" != *-gnu* ]]; then
    ./configure "${BUILD_FLAGS[@]}"
    # libtool records ${libdir} (the build sandbox's prefix) as a RUNPATH of what it links
    # against other libtool libraries, and BinaryBuilder2's audit keeps it (it only rewrites
    # RPATHs under the prefix it extracts from); the audit adds the $ORIGIN-relative ones itself.
    sed -i 's|^hardcode_libdir_flag_spec=.*|hardcode_libdir_flag_spec=""|; s|^runpath_var=LD_RUN_PATH|runpath_var=DIE_RPATH_DIE|' libtool
    make -j${nproc}
    make install
else
    STATIC_SHARED_TOGGLE=(--disable-shared --disable-static)
    # Handle error on GNU/Linux:
    #  configure: error:
    #      On GNU/Linux, building both shared and static library at the same time
    #      is not supported if --with-pic or --without-pic is used.
    #      Use either --disable-shared or --disable-static to build one type
    #      of library at a time. If both types are needed, build one at a time,
    #      possibly picking only src/liblzma/.libs/liblzma.a from the static build.
    for TOGGLE in "${STATIC_SHARED_TOGGLE[@]}"; do
        ./configure "${BUILD_FLAGS[@]}" "${TOGGLE[@]}"
        sed -i 's|^hardcode_libdir_flag_spec=.*|hardcode_libdir_flag_spec=""|; s|^runpath_var=LD_RUN_PATH|runpath_var=DIE_RPATH_DIE|' libtool
        make -j${nproc}
        make install
    done
fi

# rr_softticks: the binary tick check of the code of both libraries (the static library's
# objects, and the shared library's in the build tree): every cycle and every function entry
# ticks, rc_direct()'s asm loop included, and no tick clobbers a live flag; and the shared
# library's note and initializer. It fails the build if the patch above no longer ticks the
# loop (a compiler that does not predefine __RR_SOFTTICKS__, a new version's asm) or a new
# version adds asm with a loop. The asm is x86-64's, as is the check. (The shared library is
# not checked as a whole: the C runtime's start files linked into it do not tick.)
if [[ "${bb_full_target}" == *rr_softticks* && "${target}" == x86_64-* ]]; then
    perl ${WORKSPACE}/srcdir/softticks/check.pl --jobs ${nproc} --so ${libdir}/liblzma.so \
        ${prefix}/lib/liblzma.a src/liblzma/.libs/liblzma_la-*.o
fi
"""

# These are the platforms we will build for by default, unless further
# platforms are passed in on the command line
platforms = supported_platforms()

# The products that we will ensure are always built
products = [
    ExecutableProduct("xzdec", :xzdec),
    ExecutableProduct("lzmainfo", :lzmainfo),
    ExecutableProduct("xz", :xz),
    LibraryProduct("liblzma", :liblzma),
    ExecutableProduct("lzmadec", :lzmadec),
    # The static library is needed by libunwind
    FileProduct("lib/liblzma.a", :liblzma_a),
]

# Dependencies that must be installed before this package can be built
dependencies = Dependency[
]

# Build the tarballs, and possibly a `build.jl` as well!
build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies;
               julia_compat="1.6")
