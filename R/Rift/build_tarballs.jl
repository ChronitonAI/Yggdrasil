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
        # rift main d5b8f85, `make dist`: the asset rift-d5b8f85-x86_64-linux.tar.gz of the
        # private release dist-d5b8f85 of ChronitonAI/rift, by its API URL (BinaryBuilder2
        # authenticates with GITHUB_TOKEN or GH_TOKEN).
        ArchiveSource("https://api.github.com/repos/ChronitonAI/rift/releases/assets/604619509",
                      "eec3353a9f33106292aab432e1ee58ee6324435191e4d5224e5cb93e88f9d9a0"),
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
