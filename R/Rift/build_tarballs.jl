# rift (the Julia port of rr, record and replay with software ticks) for ygglet images.
# rift is not built here: this repackages the install tree that rift's own build makes
# (`make dist`, a juliac-trimmed executable that bundles its runtime) under /usr/lib/rift,
# with /usr/bin/rift linking to it. It is the tracer, so it is not instrumented (ygglet's
# audit exempts it); it runs on the image's glibc.
using BinaryBuilder2

build_tarballs(;
    src_name = "Rift",
    src_version = v"0.1.0",
    sources = [
        # rift main 51a4ff9, `make dist`: the asset rift-51a4ff9-x86_64-linux.tar.gz of the
        # private release dist-51a4ff9 of ChronitonAI/rift, by its API URL (BinaryBuilder2
        # authenticates with GITHUB_TOKEN or GH_TOKEN).
        ArchiveSource("https://api.github.com/repos/ChronitonAI/rift/releases/assets/606014740",
                      "16273657f91d9a928f42c68f338d0afd26a03f8134b74e8e62d06b6237f390dc"),
    ],
    script = raw"""
    mkdir -p ${prefix}/lib/rift ${bindir}
    cp -a ${WORKSPACE}/srcdir/rift-*/. ${prefix}/lib/rift/
    ln -s ../lib/rift/bin/rift ${bindir}/rift
    ln -s rift ${bindir}/rr
    mkdir -p ${prefix}/share/licenses/Rift
    echo "rift: https://github.com/ChronitonAI/rift (bundles the Julia runtime, MIT licensed)" \
        > ${prefix}/share/licenses/Rift/NOTICE
    """,
    platforms = [Platform("x86_64", "linux"; rr_softticks="1")],
    products = [ExecutableProduct("rift", :rift)],
    host_toolchains = [HostToolsToolchain()],
    target_toolchains = [CToolchain(; vendor=:gcc)],
)
