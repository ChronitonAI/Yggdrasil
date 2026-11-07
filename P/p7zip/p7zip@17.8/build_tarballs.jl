using BinaryBuilder, Pkg

const YGGDRASIL_DIR = "../../.."
include(joinpath(YGGDRASIL_DIR, "platforms", "macos_sdks.jl"))

name = "p7zip"
# Upstream uses CalVer
upstream_version = "26.05"
compact_version = replace(upstream_version, "."=>"")
version = v"17.8.5"

# Collection of sources required to build p7zip
sources = [
    ArchiveSource("https://github.com/ip7z/7zip/releases/download/$(upstream_version)/7z$(compact_version)-src.tar.xz",
                  "0b6080b8c3e7a579161d2d495224c0e51c467576cb4c7048b0ab485ef44cc22e";
                  unpack_target="7z"),
    DirectorySource("./bundled"),
]

# Bash recipe for building across all platforms
script = raw"""
# rr software ticks for the hand-written x86-64 assembly (Asm/x86, assembled by uasm): it only
# does something where the C compiler predefines __RR_SOFTTICKS__ (the softticks plugin, on
# rr_softticks platforms), which uasm is told below; elsewhere the objects are byte-identical.
# The patch is against the sources with LF line ends; uasm reads either.
cd 7z
sed -i 's/\r$//' Asm/x86/*.asm
atomic_patch -p1 ${WORKSPACE}/srcdir/patches/rr-softticks-asm.patch
cd CPP/7zip/Bundles/Alone

# RAR has a custom license
export DISABLE_RAR=1

if [[ "${target}" == *-mingw* ]]; then
    export IS_MINGW=1
    export RC=windres
fi

# ygglet (rr_softticks platforms): keep the symbol table, which makefile.gcc strips (-s); the
# audit of the software ticks names functions by it, and so does debugging under rr.
MAKE_FLAGS=()
if [[ "${bb_full_target}" == *rr_softticks* ]]; then
    MAKE_FLAGS+=(LFLAGS_STRIP=)
fi

# uasm does not see the C compiler's predefined macros: pass on __RR_SOFTTICKS__ (the
# software-ticks ABI version), which the assembly's ticks are conditional on.
MY_ASM=uasm
rr_softticks=$(echo __RR_SOFTTICKS__ | ${CC} -E -P -x c - | tr -d '[:space:]')
if [[ "${rr_softticks}" =~ ^[0-9]+$ ]]; then
    MY_ASM="uasm -D__RR_SOFTTICKS__=${rr_softticks}"
fi

if [[ "${target}" == x86_64-apple-darwin* ]]; then
    # For some reason USE_ASM doesn't work on this platform
    make -j${nproc} -f makefile.gcc "${MAKE_FLAGS[@]}"
else
    if [[ "${target}" == x86_64-* ]]; then
        make -j${nproc} -f makefile.gcc IS_X64=1 USE_ASM=1 MY_ASM="${MY_ASM}" "${MAKE_FLAGS[@]}"
    elif [[ "${target}" == aarch64-* ]]; then
        make -j${nproc} -f makefile.gcc IS_ARM64=1 USE_ASM=1 "${MAKE_FLAGS[@]}"
    else
        make -j${nproc} -f makefile.gcc "${MAKE_FLAGS[@]}"
    fi
fi

install -Dvm 755 _o/7za${exeext} "${bindir}/7z${exeext}"
install_license ../../../../DOC/copying.txt
install_license ../../../../DOC/License.txt
"""

# Require MacOS 10.13 or later to support utimensat
sources, script = require_macos_sdk("10.13", sources, script)

platforms = supported_platforms()

# The products that we will ensure are always built
products = [
    ExecutableProduct("7z", :p7zip),
]

# Dependencies that must be installed before this package can be built
dependencies = [
    HostBuildDependency(PackageSpec(name="UASM_jll", uuid="bbf38c07-751d-5a2b-a7fc-5c0acd9bd57e")),
]
# ygglet (BinaryBuilder2, rr_softticks platforms): libstdc++ and libgcc_s come from the
# toolchain's own runtimes; there is no CompilerSupportLibraries_jll to depend on.
if !any(contains("rr_softticks"), ARGS)
    dependencies = vcat(dependencies, [Dependency(PackageSpec(name="CompilerSupportLibraries_jll", uuid="e66e0078-7015-5450-92f7-15fbd957f2ae"))])
end
build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies;
    julia_compat="1.10",                   # Minimum Julia version
    preferred_gcc_version=v"8",            # GCC version
)
