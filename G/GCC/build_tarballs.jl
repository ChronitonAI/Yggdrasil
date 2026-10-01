# GCC 14.2 for ygglet images, built for an rr software ticks platform
# (`x86_64-linux-gnu-rr_softticks+1`). One build, two JLLs:
#
# - `CompilerSupportLibraries`: the runtime libraries (libgcc_s, libstdc++, libgomp, ...),
#   compiled with the software ticks plugin like everything else in the image.
# - `GCC`: the image's native C/C++ compiler (`/usr/bin/gcc`, `g++`, `cc`). Its `specs` file
#   loads the software ticks plugin (installed in its plugin directory) into every
#   compilation, so code built in the image is instrumented too. (By path: the short
#   `-fplugin=softticks_gcc` needs the `-iplugindir` that the driver only passes for a
#   `-fplugin` on its own command line.)
#
# The compiler itself is compiled by BinaryBuilder2's software ticks toolchain (instrumented).
# The target libraries are compiled by the GCC being built, so they are given the toolchain's
# plugin explicitly (same GCC release, so it loads).
using BinaryBuilder2
using BinaryBuilder2: get_default_target_spec

gcc_version = v"14.2.0"

script = raw"""
cd ${WORKSPACE}/srcdir/gcc-*/
for proj in mpfr mpc isl gmp; do
    mv ${proj}-* ${proj}
done
# Target library configure scripts must not run what they compile: it is linked against the
# image's glibc, which the build machine does not have. (As BinaryBuilder2's GCC recipe does.)
for f in $(find . -name configure); do
    sed -i -e 's&cross_compiling=no&cross_compiling=yes&g' "${f}"
done

# The sysroot the target libraries are built against: our Glibc and LinuxKernelHeaders,
# installed as the image's /usr in ${prefix}/ygglet-sysroot/usr. (Not in ${prefix} itself:
# the compiler wrappers put ${prefix}'s include and lib directories on every command line,
# and the image's libc must not leak into the compiler's own build.)
sysroot=${prefix}/ygglet-sysroot

# The software ticks plugin of the toolchain that compiles for this platform.
toolchain_plugin="$(dirname "$(dirname "$(realpath "$(which ${CC})")")")/softticks/lib/softticks_gcc.so"
if [[ ! -f "${toolchain_plugin}" ]]; then
    echo "no software ticks plugin at ${toolchain_plugin}" >&2
    exit 1
fi

mkdir -p ${WORKSPACE}/srcdir/gcc_build
cd ${WORKSPACE}/srcdir/gcc_build
if ! ${WORKSPACE}/srcdir/gcc-*/configure \
    --prefix=${prefix} \
    --build=${MACHTYPE} \
    --host=${target} \
    --target=${target} \
    --disable-multilib \
    --disable-bootstrap \
    --disable-werror \
    --disable-libsanitizer \
    --enable-threads=posix \
    --enable-languages=c,c++ \
    --enable-plugin \
    --with-arch=x86-64 \
    --with-sysroot=/ \
    --with-native-system-header-dir=/usr/include \
    --with-build-sysroot=${sysroot} \
    CC_FOR_BUILD="${HOSTCC}" \
    CXX_FOR_BUILD="${HOSTCXX}" \
    CFLAGS_FOR_TARGET="-g -O2 -fplugin=${toolchain_plugin}" \
    CXXFLAGS_FOR_TARGET="-g -O2 -fplugin=${toolchain_plugin}"; then
    cat config.log
    exit 1
fi

make -j${nproc} MAKEINFO=true
make install MAKEINFO=true

# One library directory: the image links /usr/lib64 to /usr/lib anyway.
if [[ -d ${prefix}/lib64 ]]; then
    cp -a ${prefix}/lib64/. ${prefix}/lib/
    rm -rf ${prefix}/lib64
fi
rm -f ${prefix}/lib/*.la
rm -rf ${prefix}/share/man ${prefix}/share/info
ln -sf gcc ${prefix}/bin/cc

# The software ticks plugin for this GCC, built against its own plugin headers (gmp.h
# comes from the in-tree GMP), and the specs that load it by default.
gcc_libdir=${prefix}/lib/gcc/${target}/$(echo ${WORKSPACE}/srcdir/gcc-* | sed 's/.*gcc-//')
cd ${WORKSPACE}/srcdir/rift/tools/softticks
${CXX} -std=gnu++17 -O2 -fPIC -fno-rtti -fno-exceptions -shared \
    -I${gcc_libdir}/plugin/include -idirafter gcc/compat \
    -I${WORKSPACE}/srcdir/gcc_build/gmp -Iinclude \
    gcc/softticks_gcc.cc -o ${gcc_libdir}/plugin/softticks_gcc.so
install -m 644 include/rr_softticks.h ${prefix}/include/rr_softticks.h
cat > ${gcc_libdir}/specs <<'END'
%rename cc1_options softticks_cc1_options

*cc1_options:
%(softticks_cc1_options) -fplugin=%:find-file(plugin/softticks_gcc.so)

END

install_license ${WORKSPACE}/srcdir/gcc-*/COPYING*
"""

csl_libs = ["libgcc_s", "libstdc++", "libgomp", "libatomic", "libquadmath", "libssp", "libitm"]

function extract_spec_generator(build_config, platform)
    return ExtractSpec[
        ExtractSpec(
            raw"""
            for lib in libgcc_s libstdc++ libgomp libatomic libquadmath libssp libitm; do
                for f in ${prefix}/lib/${lib}.so.*; do
                    [[ "${f}" == *.py ]] && continue
                    [[ -e "${f}" ]] && extract "${f}"
                done
            done
            extract ${prefix}/share/licenses
            """,
            [
                LibraryProduct("libgcc_s", :libgcc_s),
                LibraryProduct("libstdc++", :libstdcxx),
                LibraryProduct("libgomp", :libgomp),
            ],
            get_default_target_spec(build_config);
            jll_name = "CompilerSupportLibraries",
            platform,
        ),
        ExtractSpec(
            raw"""
            extract ${prefix}/**
            for lib in libgcc_s libstdc++ libgomp libatomic libquadmath libssp libitm; do
                rm -f ${extract_dir}/lib/${lib}.so.*
            done
            """,
            [
                ExecutableProduct("gcc", :gcc),
                ExecutableProduct("g++", :gxx),
                FileProduct("lib/gcc/x86_64-linux-gnu/14.2.0/plugin/softticks_gcc.so", :softticks_gcc),
            ],
            get_default_target_spec(build_config);
            jll_name = "GCC",
            platform,
            inter_deps = ["CompilerSupportLibraries"],
        ),
    ]
end

build_tarballs(;
    src_name = "GCC",
    src_version = gcc_version,
    sources = [
        ArchiveSource("https://mirrors.kernel.org/gnu/gcc/gcc-14.2.0/gcc-14.2.0.tar.xz",
                      "a7b39bc69cbf9e25826c5a60ab26477001f7c08d85cec04bc0e29cabed6f3cc9"),
        ArchiveSource("https://mirrors.kernel.org/gnu/mpfr/mpfr-4.1.0.tar.xz",
                      "0c98a3f1732ff6ca4ea690552079da9c597872d30e96ec28414ee23c95558a7f";
                      target="gcc-14.2.0"),
        ArchiveSource("https://mirrors.kernel.org/gnu/mpc/mpc-1.2.1.tar.gz",
                      "17503d2c395dfcf106b622dc142683c1199431d095367c6aacba6eec30340459";
                      target="gcc-14.2.0"),
        ArchiveSource("https://gcc.gnu.org/pub/gcc/infrastructure/isl-0.24.tar.bz2",
                      "fcf78dd9656c10eb8cf9fbd5f59a0b6b01386205fe1934b3b287a0a1898145c0";
                      target="gcc-14.2.0"),
        ArchiveSource("https://mirrors.kernel.org/gnu/gmp/gmp-6.2.1.tar.xz",
                      "fd4829912cddd12f84181c3451cc752be224643e87fac497b69edddadc49b4f2";
                      target="gcc-14.2.0"),
        # The software ticks plugin (tools/softticks).
        GitSource("https://github.com/ChronitonAI/rift.git",
                  "b4720f15d38a40288de63f0d0109de9eb3cccfba"),
    ],
    script,
    platforms = [Platform("x86_64", "linux"; rr_softticks="1")],
    extract_spec_generator,
    # The image's libc, headers and binutils: what this GCC compiles against and runs with.
    target_dependencies = [
        JLLSource("Glibc_jll"; target="ygglet-sysroot/usr"),
        JLLSource("LinuxKernelHeaders_jll"; target="ygglet-sysroot/usr"),
        # Runtime dependency only; out of ${prefix}, whose include/ansidecl.h would shadow GCC's.
        JLLSource("Binutils_jll"; target="ygglet-binutils"),
    ],
    host_toolchains = [CToolchain(; vendor=:gcc), HostToolsToolchain()],
    target_toolchains = [CToolchain(; vendor=:gcc)],
)
