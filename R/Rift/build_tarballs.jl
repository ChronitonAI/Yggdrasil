# rift (the Julia port of rr, record and replay with software ticks) for ygglet images.
# rift is not built here: this repackages the install tree that rift's own build makes
# (`make dist`, a juliac-trimmed executable that bundles its runtime) under /usr/lib/rift,
# with /usr/bin/rift linking to it. It is the tracer, so it is not instrumented (ygglet's
# audit exempts it); it runs on the image's glibc.
#
# TODO: host the tarball (a ChronitonAI release asset) instead of the local build.
using BinaryBuilder2

build_tarballs(;
    src_name = "Rift",
    src_version = v"0.1.0",
    sources = [
        # rift softticks-gcc14 (b4720f1), `make dist`
        ArchiveSource("file:///workspace/rift/build/dist/rift-b4720f1-x86_64-linux.tar.gz",
                      "34c743324616a886192f74f7f84039c22a14805515a304728f9d329214f3edf1"),
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
