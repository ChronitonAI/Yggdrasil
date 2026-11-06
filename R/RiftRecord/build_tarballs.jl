# rift's record-only build (`make dist RIFT_RECORD_ONLY=1`: rift record, pack, ls, ..., without
# replay or the debugger), which may be distributed publicly, for ygglet images. Packaged like
# Rift: the install tree under /usr/lib/rift, with /usr/bin/rift (and rr) linking to it. It is
# the tracer, so it is not instrumented (ygglet's audit exempts it); it runs on the image's
# glibc. A trace it records replays with the full rift.
using BinaryBuilder2

build_tarballs(;
    src_name = "RiftRecord",
    src_version = v"0.1.0",
    sources = [
        # rift main 3facb88, `make dist RIFT_RECORD_ONLY=1`: the asset
        # rift-record-3facb88-x86_64-linux.tar.gz of the public release rift-record-3facb88 of
        # ChronitonAI/rift-action, by its API URL (like R/Rift's).
        ArchiveSource("https://api.github.com/repos/ChronitonAI/rift-action/releases/assets/716377400",
                      "d4de5d1c8439a564b96cbfbe4362ea5e0924d23963f88c618b7305aede3d6333"),
    ],
    script = raw"""
    mkdir -p ${prefix}/lib/rift ${bindir}
    cp -a ${WORKSPACE}/srcdir/rift-record-*/. ${prefix}/lib/rift/
    ln -s ../lib/rift/bin/rift ${bindir}/rift
    ln -s rift ${bindir}/rr
    mkdir -p ${prefix}/share/licenses/RiftRecord
    echo "rift (record-only build), https://github.com/ChronitonAI/rift-action (bundles the Julia runtime, MIT licensed)" \
        > ${prefix}/share/licenses/RiftRecord/NOTICE
    """,
    platforms = [Platform("x86_64", "linux"; rr_softticks="1")],
    products = [ExecutableProduct("rift", :rift)],
    host_toolchains = [HostToolsToolchain()],
    target_toolchains = [CToolchain(; vendor=:gcc)],
)
