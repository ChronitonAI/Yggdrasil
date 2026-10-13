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
        # rift main 77ef888, `make dist RIFT_RECORD_ONLY=1`: the asset
        # rift-record-77ef888-x86_64-linux.tar.gz of the public release rift-record-77ef888 of
        # ChronitonAI/rift-action, by its API URL (like R/Rift's).
        ArchiveSource("https://api.github.com/repos/ChronitonAI/rift-action/releases/assets/636130491",
                      "e540d3414e3aa63b0c8be0bde1d50bad06d44b8b8fa92bf01523a4e4b7120632"),
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
