# Glibc 2.41 for ygglet images: the C library and dynamic loader of the image, built for an
# rr software ticks platform (`x86_64-linux-gnu-rr_softticks+1`), so that BinaryBuilder2's
# toolchain compiles all of it with the software ticks plugin. Its dynamic loader and static
# `_start` map the ticks countdown page first thing (patches/glibc-100-*), so instrumented code
# runs outside rr too. Installed with the JLL prefix as its root's /usr: /usr/lib holds the
# loader and libraries, and the image links /lib64 and /lib to it.
using BinaryBuilder2

version = v"2.41"

script = raw"""
cd ${WORKSPACE}/srcdir/glibc-*/
install_license COPYING* LICENSES

for p in ${WORKSPACE}/srcdir/patches/glibc-*.patch; do
    atomic_patch -p1 ${p}
done

mkdir -p ${WORKSPACE}/srcdir/glibc_build
cd ${WORKSPACE}/srcdir/glibc_build
# Everything in /usr/lib: the image's /lib and /lib64 are links to it.
cat > configparms <<END
slibdir = /usr/lib
rtlddir = /usr/lib
END
${WORKSPACE}/srcdir/glibc-*/configure \
    --prefix=/usr \
    --libdir=/usr/lib \
    --build=${MACHTYPE} \
    --host=${target} \
    --disable-multilib \
    --disable-werror \
    --disable-nscd \
    --enable-kernel=4.4 \
    libc_cv_slibdir=/usr/lib \
    CFLAGS="-O2 -g"

make -j${nproc}
make install install_root=${WORKSPACE}/srcdir/glibc_root
# The C.UTF-8 locale (/usr/lib/locale/C.utf8), which programs that ask for a UTF-8 locale
# (LANG=C.UTF-8) need; built by this glibc's own localedef.
# (install-locale-files installs SUPPORTED-LOCALES, every locale glibc knows, by default.)
make localedata/install-locale-files SUPPORTED-LOCALES="C.UTF-8/UTF-8" install_root=${WORKSPACE}/srcdir/glibc_root
test -d ${WORKSPACE}/srcdir/glibc_root/usr/lib/locale/C.utf8
[[ $(ls ${WORKSPACE}/srcdir/glibc_root/usr/lib/locale | wc -l) == 1 ]]

# Shared objects without compiled C (gconv tables, libmvec's assembly, the libnss_files and
# libnss_dns compatibility stubs) have no software ticks note, since the plugin emits it
# with the code it instruments. They hold no loops of instrumented code; mark them as
# conforming, so the image audit can require the note of every shared object.
note=${WORKSPACE}/srcdir/rr-note
# namesz=3, descsz=4, type=1, "rr\0" padded to 4, desc = ABI version 1
printf '\x03\x00\x00\x00\x04\x00\x00\x00\x01\x00\x00\x00rr\x00\x00\x01\x00\x00\x00' > ${note}
for f in $(find ${WORKSPACE}/srcdir/glibc_root -name '*.so*' -type f); do
    if ${READELF:-readelf} -h "${f}" >/dev/null 2>&1 && ! ${READELF:-readelf} -n "${f}" 2>/dev/null | grep -q '^  rr '; then
        echo "adding the software ticks note to ${f#${WORKSPACE}/srcdir/glibc_root}"
        ${OBJCOPY:-objcopy} --add-section .note.rrsoftticks=${note} \
                --set-section-flags .note.rrsoftticks=readonly \
                --set-section-alignment .note.rrsoftticks=4 "${f}"
    fi
done

# The JLL prefix is the image's /usr.
cp -a ${WORKSPACE}/srcdir/glibc_root/usr/. ${prefix}/
if [[ -d ${WORKSPACE}/srcdir/glibc_root/etc ]]; then
    mkdir -p ${prefix}/etc
    cp -a ${WORKSPACE}/srcdir/glibc_root/etc/. ${prefix}/etc/
fi
"""

build_tarballs(;
    src_name = "Glibc",
    src_version = version,
    sources = [
        ArchiveSource("https://mirrors.kernel.org/gnu/glibc/glibc-2.41.tar.xz",
                      "a5a26b22f545d6b7d7b3dd828e11e428f24f4fac43c934fb071b6a7d0828e901"),
        DirectorySource("./bundled"; follow_symlinks=true),
    ],
    script,
    platforms = [Platform("x86_64", "linux"; rr_softticks="1")],
    products = [
        # Not LibraryProducts: libc.so is a linker script, and nothing dlopens these.
        FileProduct("lib/ld-linux-x86-64.so.2", :ld_so),
        FileProduct("lib/libc.so.6", :libc),
        FileProduct("lib/libm.so.6", :libm),
    ],
    # glibc's build runs Python scripts.
    host_dependencies = [JLLSource("Python_jll")],
    host_toolchains = [CToolchain(; vendor=:gcc), HostToolsToolchain()],
    target_toolchains = [CToolchain(; vendor=:gcc)],
)
