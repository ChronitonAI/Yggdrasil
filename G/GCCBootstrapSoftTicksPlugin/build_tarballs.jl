# The rr software ticks plugin for BinaryBuilder2's bootstrap GCC (GCCBootstrap_jll, built
# with plugin support): its `:gcc_bootstrap` toolchain loads it into every compilation for a
# software ticks platform, like GCCSoftTicksPlugin for the `:gcc` one. That is how a
# software ticks platform gets the toolchain runtimes it needs to build anything else (glibc,
# GCC's runtime libraries) instrumented, as for any new platform: with the bootstrap
# compiler. A GCC plugin is built against the one GCC that loads it, hence its own JLL.
using BinaryBuilder2

build_tarballs(;
    src_name = "GCCBootstrapSoftTicksPlugin",
    src_version = v"14.2.0",
    sources = [
        # tools/softticks: the plugin and the tracee ABI header (rr_softticks.h).
        GitSource("https://github.com/ChronitonAI/rift.git",
                  "34cb5d4d4ceeeebee0320accd8976792aa6e94f8"),
    ],
    script = raw"""
    cd ${WORKSPACE}/srcdir/rift/tools/softticks
    plugin_include="$(${CC} -print-file-name=plugin)/include"
    if [[ ! -f "${plugin_include}/gcc-plugin.h" ]]; then
        echo "no GCC plugin headers in ${plugin_include}" >&2
        exit 1
    fi
    if [[ "$(${CC} -dumpfullversion)" != "14.2.0" ]]; then
        echo "GCC $(${CC} -dumpfullversion), not 14.2.0" >&2
        exit 1
    fi
    mkdir -p ${libdir} ${includedir}
    ${CXX} -std=gnu++17 -O2 -fPIC -fno-rtti -fno-exceptions -shared \
        -I${plugin_include} -idirafter gcc/compat -I${includedir} -Iinclude \
        gcc/softticks_gcc.cc -o ${libdir}/softticks_gcc.so
    install -m 644 include/rr_softticks.h ${includedir}/rr_softticks.h
    install -Dm 644 gcc/README.md ${prefix}/share/licenses/GCCBootstrapSoftTicksPlugin/README.md
    """,
    platforms = [Platform("x86_64", "linux")],
    products = [
        # Loaded by GCC, never by Julia.
        FileProduct("lib/softticks_gcc.so", :softticks_gcc),
        FileProduct("include/rr_softticks.h", :rr_softticks_h),
    ],
    # The plugin headers include gmp.h.
    target_build_time_dependencies = [JLLSource("GMP_jll")],
    host_toolchains = [CToolchain(; vendor=:gcc_bootstrap), HostToolsToolchain()],
    target_toolchains = [CToolchain(; vendor=:gcc_bootstrap)],
)
