# Linux kernel headers for ygglet images (`/usr/include/linux`, `asm`, ...): for compiling in
# the image. Headers only.
using BinaryBuilder2

build_tarballs(;
    src_name = "LinuxKernelHeaders",
    src_version = v"6.9.5",
    sources = [
        ArchiveSource("https://mirrors.edge.kernel.org/pub/linux/kernel/v6.x/linux-6.9.5.tar.xz",
                      "a51fb4ab5003a6149bd9bf4c18c9b1f0f4945c272549095ab154b9d1052f95b1"),
    ],
    script = raw"""
    cd ${WORKSPACE}/srcdir/linux-*/
    case "${target}" in
        x86_64*|i686*) linux_arch=x86 ;;
        aarch64*) linux_arch=arm64 ;;
        *) echo "unknown kernel arch for ${target}" >&2; exit 1 ;;
    esac
    make ARCH=${linux_arch} HOSTCC=${HOSTCC} mrproper
    make ARCH=${linux_arch} HOSTCC=${HOSTCC} INSTALL_HDR_PATH=${prefix} -j${nproc} headers_install
    install_license COPYING LICENSES/preferred/GPL-2.0 LICENSES/exceptions/Linux-syscall-note
    """,
    platforms = [Platform("x86_64", "linux"; rr_softticks="1")],
    products = [FileProduct("include/linux/version.h", :linux_version_h)],
    host_toolchains = [CToolchain(; vendor=:gcc), HostToolsToolchain()],
    target_toolchains = [CToolchain(; vendor=:gcc)],
)
