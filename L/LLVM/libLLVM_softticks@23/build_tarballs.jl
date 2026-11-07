# libLLVM and LLD 23.1.4 for Julia, built with BinaryBuilder2 for the rr software ticks
# platforms (`x86_64-linux-gnu-rr_softticks+1`). One build, two JLLs, laid out like the
# upstream `libLLVM@23` and `LLD@23` extractions of `LLVM_full@23` (what Julia's
# deps/llvm.mk installs with USE_BINARYBUILDER_LLVM=1):
#
# - `libLLVM`: lib/libLLVM.so.23.1jl (and the libLLVM-23jl.so and libLLVM.so links),
#   tools/llvm-config, include/llvm{,-c}, the component archives lib/libLLVM*.a and
#   lib/cmake/llvm;
# - `LLD`: tools/lld (with its ld.lld, ld64.lld, lld-link and wasm-ld links) and
#   tools/dsymutil, linked against libLLVM, include/lld, lib/liblld*.a and lib/cmake/lld.
#
# Same source as LLVM_full@23 (JuliaLang/llvm-project julia-23.1.4-1, which carries Julia's
# patches, plus the bundled patches of LLVM_full@23) and the same LLVM configuration as
# ../common.jl's buildscript, but only the projects Julia needs (llvm, lld): no clang,
# compiler-rt or MLIR, which v1's two-stage LLVM_full + extraction recipes build and which
# take well over the time one build may have. Assembly is kept (BLAKE3's .S files).
using BinaryBuilder2
using BinaryBuilder2: get_default_target_spec

llvm_version = v"23.1.4"

script = raw"""
cd ${WORKSPACE}/srcdir/llvm-project
LLVM_SRCDIR=${WORKSPACE}/srcdir/llvm-project/llvm

# The patches LLVM_full@23 applies (../LLVM_full@23/bundled), in the same places. Only
# patches/0200-templates.patch touches what is built here (lld); the others are applied
# anyway, so that the source tree is LLVM_full's.
for f in ${WORKSPACE}/srcdir/patches/*.patch; do
    atomic_patch -p1 ${f}
done
(cd compiler-rt && for f in ${WORKSPACE}/srcdir/crt_patches/*.patch; do atomic_patch -p1 ${f}; done)
(cd libcxx && for f in ${WORKSPACE}/srcdir/libcxx_patches/*.patch; do atomic_patch -p1 ${f}; done)

# LLVM's CMake needs Python 3 (the host's Python_jll).
export PATH="${host_bindir}:${PATH}"
PYTHON3=${host_bindir}/python3

# The tablegen tools and llvm-config for the build machine (as in common.jl): for CMake
# this is a cross build (CMAKE_SYSTEM_NAME is set for the rr_softticks platform), so LLVM
# would otherwise configure a native build of them itself.
mkdir ${WORKSPACE}/bootstrap
pushd ${WORKSPACE}/bootstrap
cmake -GNinja ${LLVM_SRCDIR} \
    -DCMAKE_TOOLCHAIN_FILE=${CMAKE_HOST_TOOLCHAIN} \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CROSSCOMPILING=False \
    -DLLVM_TARGETS_TO_BUILD:STRING=host \
    -DLLVM_HOST_TRIPLE=${MACHTYPE} \
    -DLLVM_ENABLE_ZLIB=OFF \
    -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DPython3_EXECUTABLE=${PYTHON3}
ninja -j${nproc} llvm-tblgen llvm-min-tblgen llvm-config
popd

mkdir ${WORKSPACE}/build && cd ${WORKSPACE}/build
CMAKE_FLAGS=()
CMAKE_FLAGS+=(-DCMAKE_TOOLCHAIN_FILE=${CMAKE_TARGET_TOOLCHAIN})
CMAKE_FLAGS+=(-DCMAKE_INSTALL_PREFIX=${prefix})
CMAKE_FLAGS+=(-DCMAKE_CROSSCOMPILING=True)
CMAKE_FLAGS+=(-DCMAKE_SHARED_LINKER_FLAGS=-Wl,--build-id)
# Release, without assertions (libLLVM, not libLLVM_assert)
CMAKE_FLAGS+=(-DCMAKE_BUILD_TYPE=Release)
# Julia's targets (deps/llvm.mk), in common.jl's order
CMAKE_FLAGS+=(-DLLVM_TARGETS_TO_BUILD:STRING="host;AMDGPU;NVPTX;WebAssembly;BPF;AVR")
CMAKE_FLAGS+=(-DLLVM_ENABLE_PROJECTS:STRING=lld)
CMAKE_FLAGS+=(-DLLVM_BINDINGS_LIST="")
# zlib and zstd from this platform's Zlib_jll and Zstd_jll in ${prefix}; named explicitly, as
# CMake's own install prefix (the toolchain's CMake_jll) comes first in its search path.
CMAKE_FLAGS+=(-DLLVM_ENABLE_ZLIB=FORCE_ON -DZLIB_INCLUDE_DIR=${includedir} -DZLIB_LIBRARY=${libdir}/libz.so)
CMAKE_FLAGS+=(-DLLVM_ENABLE_ZSTD=FORCE_ON -Dzstd_INCLUDE_DIR=${includedir} -Dzstd_LIBRARY=${libdir}/libzstd.so)
CMAKE_FLAGS+=(-DLLVM_ENABLE_LIBXML2=OFF)
CMAKE_FLAGS+=(-DLLVM_INCLUDE_DOCS=OFF -DLLVM_ENABLE_TERMINFO=OFF -DHAVE_HISTEDIT_H=OFF -DHAVE_LIBEDIT=OFF)
# Not built by LLVM_full's default target either; skipping them saves configure time.
CMAKE_FLAGS+=(-DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF)
# The shared library Julia links: libLLVM.so.23.1jl, with JL_LLVM_23.1 symbol versions
CMAKE_FLAGS+=(-DLLVM_BUILD_LLVM_DYLIB:BOOL=ON -DLLVM_LINK_LLVM_DYLIB:BOOL=ON)
CMAKE_FLAGS+=(-DLLVM_VERSION_SUFFIX:STRING="jl")
CMAKE_FLAGS+=(-DLLVM_SHLIB_SYMBOL_VERSION:STRING="JL_LLVM_23.1")
# Julia expects the tools in tools/, not bin/
CMAKE_FLAGS+=(-DCMAKE_INSTALL_BINDIR="tools")
# perf and VTune JIT event listeners, as on upstream's x86_64 Linux (ittapi: a source here,
# CMake would clone it)
CMAKE_FLAGS+=(-DLLVM_USE_PERF=1)
CMAKE_FLAGS+=(-DLLVM_USE_INTEL_JITEVENTS=1 -DITTAPI_SOURCE_DIR=${WORKSPACE}/srcdir/ittapi)
CMAKE_FLAGS+=(-DLLVM_WINDOWS_PREFER_FORWARD_SLASH=False)
CMAKE_FLAGS+=(-DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF)
# The bootstrapped tools
CMAKE_FLAGS+=(-DLLVM_TABLEGEN=${WORKSPACE}/bootstrap/bin/llvm-tblgen)
CMAKE_FLAGS+=(-DLLVM_HEADERS_TABLEGEN=${WORKSPACE}/bootstrap/bin/llvm-min-tblgen)
CMAKE_FLAGS+=(-DLLVM_CONFIG_PATH=${WORKSPACE}/bootstrap/bin/llvm-config)
CMAKE_FLAGS+=(-DLLVM_NATIVE_TOOL_DIR=${WORKSPACE}/bootstrap/bin)
CMAKE_FLAGS+=(-DLLVM_HOST_TRIPLE=${target})
CMAKE_FLAGS+=(-DBUG_REPORT_URL="https://github.com/julialang/julia")
CMAKE_FLAGS+=(-DPython3_EXECUTABLE=${PYTHON3})
# https://bugs.llvm.org/show_bug.cgi?id=48221
CMAKE_FLAGS+=(-DCMAKE_CXX_FLAGS="-fno-gnu-unique")

cmake -GNinja ${LLVM_SRCDIR} "${CMAKE_FLAGS[@]}"
ninja -j${nproc}
ninja install

install_license ${WORKSPACE}/srcdir/llvm-project/llvm/LICENSE.TXT
"""

function extract_spec_generator(build_config, platform)
    target_spec = get_default_target_spec(build_config)
    return ExtractSpec[
        ExtractSpec(
            raw"""
            extract ${prefix}/include/llvm ${prefix}/include/llvm-c
            extract ${prefix}/tools/llvm-config
            extract ${prefix}/lib/libLLVM*.so* ${prefix}/lib/libLLVM*.a
            extract ${prefix}/lib/cmake/llvm
            """,
            [
                LibraryProduct(["libLLVM", "libLLVM-23jl"], :libllvm),
                ExecutableProduct("tools/llvm-config", :llvm_config),
            ],
            target_spec;
            jll_name = "libLLVM",
            platform,
        ),
        ExtractSpec(
            raw"""
            # Licenses go to share/licenses/${SRC_NAME} (this JLL's, not the build's name).
            export SRC_NAME=LLD
            extract ${prefix}/include/lld
            for tool in lld ld.lld ld64.lld lld-link wasm-ld dsymutil; do
                extract ${prefix}/tools/${tool}
            done
            extract ${prefix}/lib/liblld*.a
            extract ${prefix}/lib/cmake/lld
            install_license ${prefix}/share/licenses/libLLVM/LICENSE.TXT
            """,
            [
                ExecutableProduct("tools/lld", :lld),
                ExecutableProduct("tools/ld.lld", :ld_lld),
                ExecutableProduct("tools/ld64.lld", :ld64_lld),
                ExecutableProduct("tools/lld-link", :lld_link),
                ExecutableProduct("tools/wasm-ld", :wasm_ld),
                ExecutableProduct("tools/dsymutil", :dsymutil),
            ],
            target_spec;
            jll_name = "LLD",
            platform,
            inter_deps = ["libLLVM"],
        ),
    ]
end

build_tarballs(;
    src_name = "libLLVM",
    src_version = llvm_version,
    sources = [
        # julia-23.1.4-1 (../common.jl's llvm_tags)
        GitSource("https://github.com/JuliaLang/llvm-project.git",
                  "3d876d0b0d8b4ac77362bd55cd030de355e83a9e"),
        # v3.18.12, what llvm/lib/ExecutionEngine/IntelJITProfiling would clone
        GitSource("https://github.com/intel/ittapi.git",
                  "c2a515bd34f37ba83c61474a04cd2bba57fde67e"),
        DirectorySource(joinpath(@__DIR__, "..", "LLVM_full@23", "bundled")),
    ],
    script,
    platforms = [Platform("x86_64", "linux"; rr_softticks="1")],
    extract_spec_generator,
    target_dependencies = [
        JLLSource("Zlib_jll"),
        JLLSource("Zstd_jll"),
    ],
    host_dependencies = [JLLSource("Python_jll")],
)
