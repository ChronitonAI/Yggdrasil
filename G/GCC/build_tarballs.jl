# GCC 14.2 for ygglet images, built for an rr software ticks platform
# (`x86_64-linux-gnu-rr_softticks+1`). One build, two JLLs:
#
# - `CompilerSupportLibraries`: the runtime libraries (libgcc_s, libstdc++, libgfortran,
#   libquadmath, libgomp, ...), compiled with the software ticks plugin like everything else
#   in the image.
# - `GCC`: the image's native C, C++ and Fortran compiler (`/usr/bin/gcc`, `g++`, `cc`,
#   `gfortran`). Its `specs` file loads the software ticks plugin (installed in its plugin
#   directory) into every compilation, so code built in the image is instrumented too. (By
#   path: the short `-fplugin=softticks_gcc` needs the `-iplugindir` that the driver only
#   passes for a `-fplugin` on its own command line.)
#
# The compiler itself is compiled by BinaryBuilder2's software ticks toolchain (instrumented).
# The target libraries are compiled by the GCC being built, so they are given the toolchain's
# plugin explicitly (same GCC release, so it loads): the C and C++ ones through
# CFLAGS/CXXFLAGS_FOR_TARGET, the Fortran ones (libgfortran's, libgomp's omp_lib) through
# FCFLAGS in the environment, which their `configure` takes (GCC has no FCFLAGS_FOR_TARGET).
# The plugin does not see the runtime libraries' hand-written assembly (libgcc's morestack.S
# and -mcall-ms2sysv-xlogues stubs, libitm's sjlj.S), which ticks by hand
# (bundled/patches/gcc-14.2.0-rr-softticks-asm.patch; the plugin predefines __RR_SOFTTICKS__
# for .S files too) and is checked in the object code after the build.
using BinaryBuilder2
using BinaryBuilder2: get_default_target_spec

gcc_version = v"14.2.0"

script = raw"""
cd ${WORKSPACE}/srcdir/gcc-*/
for proj in mpfr mpc isl gmp; do
    mv ${proj}-* ${proj}
done
# Software ticks in the runtime libraries' x86-64 assembly (a no-op without __RR_SOFTTICKS__)
atomic_patch -p1 ${WORKSPACE}/srcdir/patches/gcc-14.2.0-rr-softticks-asm.patch
# Target library configure scripts must not run what they compile: it is linked against the
# image's glibc, which the build machine does not have. Only the target libraries': GCC's
# own configure must still see a native compiler (a "cross" one looks for target-prefixed
# tools, e.g. collect2 for `target-ld`, and links C++ without libgcc_s). libbacktrace is a
# target library too (for libgfortran's backtraces); its configure for the host's
# libbacktrace runs nothing either.
for d in libgcc libstdc++-v3 libgfortran libbacktrace libgomp libatomic libquadmath libssp libitm libvtv; do
    [[ -f ${d}/configure ]] && sed -i -e 's&cross_compiling=no&cross_compiling=yes&g' ${d}/configure
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
export FCFLAGS="-g -O2 -fplugin=${toolchain_plugin}"

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
    --enable-languages=c,c++,fortran \
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

# The software ticks of the hand-written assembly, checked in the object code by OpenBLAS's
# softticks/check.pl: every assembled member of libgcc.a, libgcc_eh.a and libitm.a, and of the
# shared libitm's objects, ticks on every cycle and on every path from a function's entry,
# without clobbering a live flag (GTM_longjmp's indirect jump is its longjmp out); and
# libitm.so has the note and the initializer. It fails the build if the patch's ticks did not
# land (a compiler that does not predefine __RR_SOFTTICKS__ for .S files, a hunk that applies
# elsewhere after a version bump) or a new version brings assembly without them. Compiled
# code is the plugin's (--asm-only). The self-test first: an objdump whose output the check
# misreads cannot pass as "no findings".
gcc_libdir=${prefix}/lib/gcc/${target}/$(echo ${WORKSPACE}/srcdir/gcc-* | sed 's/.*gcc-//')
perl ${WORKSPACE}/srcdir/softticks/check.pl --selftest
perl ${WORKSPACE}/srcdir/softticks/check.pl --jobs ${nproc} --asm-only --longjmp GTM_longjmp \
    --so ${prefix}/lib/libitm.so.1.0.0 \
    ${gcc_libdir}/libgcc.a ${gcc_libdir}/libgcc_eh.a ${prefix}/lib/libitm.a \
    ${WORKSPACE}/srcdir/gcc_build/*/libitm/.libs/*.o
# collect2 looks for real-ld and collect-ld next to it, then (in this build) a target-prefixed
# name, never a plain `ld`: point real-ld at the image's /usr/bin/ld (from Binutils).
gcc_libexecdir=${prefix}/libexec/gcc/${target}/$(echo ${WORKSPACE}/srcdir/gcc-* | sed 's/.*gcc-//')
ln -sf ../../../../bin/ld ${gcc_libexecdir}/real-ld

# The software ticks plugin for this GCC, built against its own plugin headers (gmp.h
# comes from the in-tree GMP), and the specs that load it by default.
gcc_libdir=${prefix}/lib/gcc/${target}/$(echo ${WORKSPACE}/srcdir/gcc-* | sed 's/.*gcc-//')
cd ${WORKSPACE}/srcdir/rift/tools/softticks
${CXX} -std=gnu++17 -O2 -fPIC -fno-rtti -fno-exceptions -shared \
    -I${gcc_libdir}/plugin/include -idirafter gcc/compat \
    -I${WORKSPACE}/srcdir/gcc_build/gmp -Iinclude \
    gcc/softticks_gcc.cc -o ${gcc_libdir}/plugin/softticks_gcc.so
install -m 644 include/rr_softticks.h ${prefix}/include/rr_softticks.h
# A specs file in the library directory replaces the built-in specs entirely: the driver
# then skips its built-in initialization (which adds --eh-frame-hdr to the link and
# libgcc_s to the libraries), so it must be a complete dump, with the plugin added to
# - cpp_unique_options: the preprocessor options of compilations, of -E and of assembler-with-
#   cpp (.S) files alike, so the plugin's __RR_SOFTTICKS__ is defined for all of them;
# - cc1_options: the options of the compilers proper (cc1, cc1plus, f951, lto1). Fortran that
#   is not preprocessed (.f, .f90) only gets these, and so does the compilation of a C file
#   already preprocessed by -save-temps. GCC loads a plugin given twice by the same path
#   once, as C compilations get both.
# The build tree's xgcc runs here; the installed driver needs the image's glibc.
softticks_spec=" -fplugin=%:find-file(plugin/softticks_gcc.so)"
${WORKSPACE}/srcdir/gcc_build/gcc/xgcc -dumpspecs | awk -v spec="${softticks_spec}" '
    { print }
    /^\*(cpp_unique_options|cc1_options):$/ { getline; print $0 spec }
' > ${gcc_libdir}/specs
[[ "$(grep -A1 -E '^\*(cpp_unique_options|cc1_options):$' ${gcc_libdir}/specs | grep -cF -- "${softticks_spec}")" == 2 ]]
grep -q -- '--eh-frame-hdr' ${gcc_libdir}/specs

# Check the specs and both plugins with the build tree's drivers (given the specs file, and
# the library directory to find the plugin in): ticks and the note in Fortran that is not
# preprocessed, ticks in C compiled from a -save-temps .i file, and __RR_SOFTTICKS__ in
# Fortran that is preprocessed (the plugin defines it in gfortran's preprocessor too) and C.
mkdir -p ${WORKSPACE}/srcdir/specs_check
cd ${WORKSPACE}/srcdir/specs_check
xflags=( -B${WORKSPACE}/srcdir/gcc_build/gcc/ -B${gcc_libdir}/ -specs=${gcc_libdir}/specs )
xgcc=( ${WORKSPACE}/srcdir/gcc_build/gcc/xgcc "${xflags[@]}" )
xgfortran=( ${WORKSPACE}/srcdir/gcc_build/gcc/gfortran "${xflags[@]}" )
printf 'subroutine s(n)\n  integer :: n, i\n  do i = 1, n\n    call t(i)\n  end do\nend subroutine s\n' > floop.f90
"${xgfortran[@]}" -O2 -S floop.f90 -o floop.s
grep -q 'decq.*0x70001800' floop.s
grep -q '\.note\.rrsoftticks' floop.s
printf 'void t(int);\nvoid s(int n) { for (int i = 0; i < n; i++) t(i); }\n' > cloop.c
"${xgcc[@]}" -O2 -save-temps -S cloop.c
grep -q 'decq.*0x70001800' cloop.s
printf '#ifdef __RR_SOFTTICKS__\nmacro=__RR_SOFTTICKS__\n#else\nmacro=none\n#endif\n' > macro.F90
cp macro.F90 macro.c
[[ "$("${xgfortran[@]}" -E -P macro.F90 | grep '^macro=')" == "macro=1" ]]
[[ "$("${xgcc[@]}" -E -P macro.c | grep '^macro=')" == "macro=1" ]]
cd ${WORKSPACE}/srcdir

install_license ${WORKSPACE}/srcdir/gcc-*/COPYING*
"""

# The runtime libraries, which go into CompilerSupportLibraries (not GCC)
csl_libs = ["libgcc_s", "libstdc++", "libgfortran", "libgomp", "libatomic", "libquadmath", "libssp", "libitm"]
csl_libs_loop = "for lib in $(join(csl_libs, " ")); do\n"

function extract_spec_generator(build_config, platform)
    return ExtractSpec[
        ExtractSpec(
            csl_libs_loop * raw"""
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
                LibraryProduct("libgfortran", :libgfortran),
                # libgfortran's dependency
                LibraryProduct("libquadmath", :libquadmath),
            ],
            get_default_target_spec(build_config);
            jll_name = "CompilerSupportLibraries",
            platform,
        ),
        ExtractSpec(
            raw"""
            extract ${prefix}/**
            """ * csl_libs_loop * raw"""
                rm -f ${extract_dir}/lib/${lib}.so.*
            done
            """,
            [
                ExecutableProduct("gcc", :gcc),
                ExecutableProduct("g++", :gxx),
                ExecutableProduct("gfortran", :gfortran),
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
                  "62a65ffdc8be28ce166bcdd6dd51db7ec32702c6"),
        DirectorySource("./bundled"),
        # The binary check of the software ticks, OpenBLAS's (run after the install)
        DirectorySource(joinpath(@__DIR__, "..", "..", "O", "OpenBLAS", "softticks"); target="softticks"),
    ],
    script,
    platforms = [Platform("x86_64", "linux"; rr_softticks="1")],
    extract_spec_generator,
    # The image's libc, headers and binutils: what this GCC compiles against and runs with.
    # Build-time only: BinaryBuilder2 makes a build's runtime dependencies dependencies of
    # every JLL it produces, and CompilerSupportLibraries_jll must not pull glibc and binutils
    # into the builds of everything that links libstdc++. Images list them explicitly.
    target_build_time_dependencies = [
        JLLSource("Glibc_jll"; target="ygglet-sysroot/usr"),
        JLLSource("LinuxKernelHeaders_jll"; target="ygglet-sysroot/usr"),
        # Runtime dependency only; out of ${prefix}, whose include/ansidecl.h would shadow GCC's.
        JLLSource("Binutils_jll"; target="ygglet-binutils"),
    ],
    host_toolchains = [CToolchain(; vendor=:gcc), HostToolsToolchain()],
    target_toolchains = [CToolchain(; vendor=:gcc)],
)
