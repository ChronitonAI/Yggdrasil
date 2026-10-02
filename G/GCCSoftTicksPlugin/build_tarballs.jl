# The rr software ticks plugin for GCC (ygglet): BinaryBuilder2's CToolchain loads it into
# every compilation for a software ticks platform (`rr_softticks` tag, e.g.
# `x86_64-linux-gnu-rr_softticks+1`). A GCC plugin only loads into the GCC release it was
# built against, so the version is the GCC version, and the plugin is built with the
# toolchain's own GCC and plugin headers.
using BinaryBuilder2

build_tarballs(;
    src_name = "GCCSoftTicksPlugin",
    src_version = v"14.2.0",
    sources = [
        # tools/softticks: the plugin and the tracee ABI header (rr_softticks.h).
        GitSource("https://github.com/ChronitonAI/rift.git",
                  "2b81cfff780b51dd752ae96b176d0f0e27ebada3"),
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
    install -Dm 644 gcc/README.md ${prefix}/share/licenses/GCCSoftTicksPlugin/README.md
    """,
    platforms = [Platform("x86_64", "linux")],
    products = [
        # Loaded by GCC, never by Julia.
        FileProduct("lib/softticks_gcc.so", :softticks_gcc),
        FileProduct("include/rr_softticks.h", :rr_softticks_h),
    ],
    # The plugin headers include gmp.h.
    target_build_time_dependencies = [JLLSource("GMP_jll")],
    host_toolchains = [CToolchain(; vendor=:gcc), HostToolsToolchain()],
    target_toolchains = [CToolchain(; vendor=:gcc)],
)
