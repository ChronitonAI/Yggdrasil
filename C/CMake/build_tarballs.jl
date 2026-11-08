# Note that this script can accept some limited command-line arguments, run
# `julia build_tarballs.jl --help` to see a usage message.
using BinaryBuilder

name = "CMake"
version = v"4.4.1"

# Collection of sources required to build CMake
sources = [
    GitSource("https://github.com/Kitware/CMake", "d1cffecacdfd7d6fb0cda0d1e0bf1ba30b967019"),
    DirectorySource("./bundled"),
]

# Bash recipe for building across all platforms
script = raw"""
cd ${WORKSPACE}/srcdir/CMake

# The musl in our toolchains (1.1.19) predates pthread_getname_np (musl 1.2.3)
atomic_patch -p1 ${WORKSPACE}/srcdir/patches/cmlibuv-musl-pthread_getname_np.patch

# rr software ticks (rr_softticks platforms): the compiler pass ticks all compiled code, but
# not the loop in the x86-64 inline asm of the bundled liblzma's rc_direct()
# (liblzma/rangecoder/range_decoder.h, LZMA_RANGE_DECODER_CONFIG & 0x100), a cycle without a
# tick in lzma_decode(). X/XZ ticks that loop by hand, so CMake links the image's liblzma
# instead of its own copy, and with it the image's zlib, zstd, bzip2 and expat (the
# dependencies below): one copy of each in the image. The other bundled libraries (curl,
# nghttp2, libarchive, libuv, jsoncpp, librhash, cppdap) have no asm loops and stay. Elsewhere
# the command line is unchanged.
system_libraries=()
if [[ "${bb_full_target}" == *rr_softticks* ]]; then
    system_libraries=(
        -DCMAKE_USE_SYSTEM_LIBRARY_LIBLZMA=ON
        -DCMAKE_USE_SYSTEM_LIBRARY_ZLIB=ON
        -DCMAKE_USE_SYSTEM_LIBRARY_ZSTD=ON
        -DCMAKE_USE_SYSTEM_LIBRARY_BZIP2=ON
        -DCMAKE_USE_SYSTEM_LIBRARY_EXPAT=ON
    )
fi

cmake -B build -G Ninja \
    -DCMAKE_INSTALL_PREFIX=${prefix} \
    -DCMAKE_BUILD_TYPE:STRING=Release \
    -DCMAKE_TOOLCHAIN_FILE=${CMAKE_TARGET_TOOLCHAIN} \
    -DBUILD_TESTING:BOOL=OFF \
    "${system_libraries[@]}"
# ninja directly rather than `cmake --build`/`cmake --install`: BinaryBuilder2's cmake wrapper
# prepends -DCMAKE_TOOLCHAIN_FILE=... to every cmake command line, which breaks those modes.
ninja -C build -j${nproc}
ninja -C build install

install_license LICENSE.rst

# rr_softticks: the programs link the image's libraries and carry no copy of them, so none
# of the bundled liblzma's asm. (The binary tick check of the programs is the image's: the
# OpenBLAS recipe's check.pl does not know the noreturn functions of compiled C++, and would
# see thousands of cycles through calls to them.)
if [[ "${bb_full_target}" == *rr_softticks* ]]; then
    for exe in ${bindir}/cmake ${bindir}/ctest ${bindir}/cpack; do
        for lib in liblzma.so.5 libz.so.1 libzstd.so.1 libbz2.so.1.0 libexpat.so.1; do
            if ! ${READELF} -d ${exe} | grep '(NEEDED)' | grep -F "[${lib}]" > /dev/null; then
                echo "${exe} does not link ${lib}" >&2
                exit 1
            fi
        done
        # (global symbols only: libarchive's xz filter has static functions named lzma_*)
        if ${NM} --defined-only --extern-only ${exe} | awk '{ print $NF }' |
                grep -E '^(lzma_|cm_zlib_|deflate$|inflate$|ZSTD_|ZDICT_|BZ2_|XML_)'; then
            echo "${exe} defines symbols of a bundled liblzma, zlib, zstd, bzip2 or expat (above)" >&2
            exit 1
        fi
    done
fi
"""

# Build for all supported platforms.
platforms = expand_cxxstring_abis(supported_platforms())

# The products that we will ensure are always built
products = [
    ExecutableProduct("cmake", :cmake),
]

# Dependencies that must be installed before this package can be built
dependencies = [
    Dependency("OpenSSL_jll"; compat="3.0.16")
]
# ygglet (BinaryBuilder2, rr_softticks platforms): the libraries CMake would otherwise bundle
# (see the script).
if any(contains("rr_softticks"), ARGS)
    append!(dependencies, [
        Dependency("XZ_jll"; compat="5.8.1"),
        Dependency("Zlib_jll"; compat="1.2.12"),
        Dependency("Zstd_jll"; compat="1.5.7"),
        Dependency("Bzip2_jll"; compat="1.0.9"),
        Dependency("Expat_jll"; compat="2.6.5"),
    ])
end

# Build the tarballs, and possibly a `build.jl` as well.
# We use GCC 7 because we need C++17 (`std::make_unique`)
build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies;
               julia_compat="1.6", preferred_gcc_version=v"7")
