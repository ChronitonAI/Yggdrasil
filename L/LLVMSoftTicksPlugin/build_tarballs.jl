# The rr software ticks pass plugin for clang (ygglet): BinaryBuilder2's CToolchain loads it
# (`-fpass-plugin=`) into every compilation of its clang vendor for a software ticks platform
# (`rr_softticks` tag, e.g. `x86_64-linux-gnu-rr_softticks+1`). A pass plugin takes LLVM's
# symbols from the clang that loads it, so it only loads into the LLVM major version whose
# headers it was built against: the version is that of the Clang_jll/libLLVM_jll the
# CToolchain uses (17.0.7, LLVM 17.0.6), and the plugin is built against that toolchain's own
# LLVM headers. libLLVM is built with GCC and libstdc++, so the plugin uses libstdc++ too.
using BinaryBuilder2

build_tarballs(;
    src_name = "LLVMSoftTicksPlugin",
    src_version = v"17.0.7",
    sources = [
        # tools/softticks: the plugin and the tracee ABI header (rr_softticks.h).
        GitSource("https://github.com/ChronitonAI/rift.git",
                  "fdc1827c5941a37bc56416fc3ba0bdc6bd2caf8c"),
    ],
    script = raw"""
    cd ${WORKSPACE}/srcdir/rift/tools/softticks
    # The clang toolchain's prefix (Clang_jll + libLLVM_jll) is next to its wrappers.
    llvm_prefix="$(dirname "$(dirname "$(command -v "${CC}")")")/clang"
    llvm_config="${llvm_prefix}/bin/llvm-config"
    llvm_version="$("${llvm_config}" --version)"
    if [[ "${llvm_version%%.*}" != "17" ]]; then
        echo "LLVM ${llvm_version} in ${llvm_prefix}, not 17" >&2
        exit 1
    fi
    if [[ "$("${llvm_config}" --shared-mode)" != "shared" ]]; then
        echo "${llvm_prefix}'s clang does not use a shared libLLVM" >&2
        exit 1
    fi
    mkdir -p ${libdir} ${includedir}
    # LLVM's flags (-std=c++17 -fno-exceptions, -fno-rtti, LLVM's include directory).
    # No -lLLVM: the plugin takes LLVM's symbols from the process that loads it.
    ${CXX} $("${llvm_config}" --cxxflags) -fno-rtti -fPIC -O2 -Wall -Wno-unused-parameter \
        -Iinclude -shared llvm/SoftTicks.cpp -o ${libdir}/softticks_llvm.so
    install -m 644 include/rr_softticks.h ${includedir}/rr_softticks.h
    install -Dm 644 llvm/README.md ${prefix}/share/licenses/LLVMSoftTicksPlugin/README.md
    """,
    platforms = [Platform("x86_64", "linux")],
    products = [
        # Loaded by clang, never by Julia.
        FileProduct("lib/softticks_llvm.so", :softticks_llvm),
        FileProduct("include/rr_softticks.h", :rr_softticks_h),
    ],
    host_toolchains = [CToolchain(; vendor=:gcc), HostToolsToolchain()],
    target_toolchains = [CToolchain(; vendor=:clang)],
)
