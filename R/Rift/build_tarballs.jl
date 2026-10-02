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
        # rift main 04192a2, `make dist`: the asset rift-04192a2-x86_64-linux.tar.gz of the
        # private release dist-04192a2 of ChronitonAI/rift, by its API URL (BinaryBuilder2
        # authenticates with GITHUB_TOKEN or GH_TOKEN).
        ArchiveSource("https://api.github.com/repos/ChronitonAI/rift/releases/assets/606512133",
                      "e6050095c8416c3c7299136cb1f59f1c5ba96a75e0fcfa266b2e62a32156fdc6"),
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
