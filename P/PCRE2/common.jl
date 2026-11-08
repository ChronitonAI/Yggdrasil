# Note that this script can accept some limited command-line arguments, run
# `julia build_tarballs.jl --help` to see a usage message.
using BinaryBuilder, Pkg
using BinaryBuilderBase: sanitize

# `version` is the package version; its major and minor components select the upstream release.
# `widths` lists the code unit widths (8, 16, 32) whose libraries are built.
# `julia_compat` is the Julia compat bound of the package.
function build_pcre2(ARGS, name::String, version::VersionNumber, widths::Vector{Int};
                     julia_compat::String="1.9")

    # Collection of sources required to complete build
    sources = [
        # We use an archive because (a) the archives are signed, hence
        # presumably immutable, and (b) the git source uses submodules.
        ArchiveSource("https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$(version.major).$(version.minor)/pcre2-$(version.major).$(version.minor).tar.bz2",
                      "53c156e1ba416a20da8e65395daa132da0d80e76910424caca3fcdae7831d384"),
        DirectorySource(joinpath(@__DIR__, "bundled")),
    ]

    # Bash recipe for building across all platforms
    script = "WIDTHS=\"$(join(widths, ' '))\"\n" * raw"""
cd $WORKSPACE/srcdir/pcre2*

# rr software ticks in the JIT's generated code. It only does something when the compiler
# predefines __RR_SOFTTICKS__ (the softticks plugin on rr_softticks platforms); elsewhere
# the library is unchanged.
atomic_patch -p1 ${WORKSPACE}/srcdir/patches/pcre2-10.49-jit-rr-softticks.patch

if [[ ${bb_full_target} == *-sanitize+memory* ]]; then
    # Install msan runtime (for clang)
    cp -rL ${libdir}/linux/* /opt/x86_64-linux-musl/lib/clang/*/lib/linux/
fi

# Force optimization
export CFLAGS="${CFLAGS} -O3"

config_flags=()
for width in 8 16 32; do
    if [[ " ${WIDTHS} " == *" ${width} "* ]]; then
        config_flags+=(--enable-pcre2-${width})
    else
        config_flags+=(--disable-pcre2-${width})
    fi
done

./configure --prefix=${prefix} --build=${MACHTYPE} --host=${target} \
    --disable-symvers \
    --enable-jit \
    "${config_flags[@]}"
# libtool records ${libdir} (the build sandbox's prefix) as a RUNPATH of what it links
# against other libtool libraries, and BinaryBuilder2's audit keeps it (it only rewrites
# RPATHs under the prefix it extracts from); the audit adds the $ORIGIN-relative ones itself.
sed -i 's|^hardcode_libdir_flag_spec=.*|hardcode_libdir_flag_spec=""|; s|^runpath_var=LD_RUN_PATH|runpath_var=DIE_RPATH_DIE|' libtool

make -j${nproc}
make install

# On windows we also need libpcre2-${width}.dll
if [[ ${target} == *mingw* ]]; then
    for width in ${WIDTHS}; do
        ln -s libpcre2-${width}-0.dll ${libdir}/libpcre2-${width}.dll
    done
fi
"""

    # These are the platforms we will build for by default, unless further
    # platforms are passed in on the command line
    platforms = supported_platforms()
    push!(platforms, Platform("x86_64", "linux"; sanitize="memory"))

    # The products that we will ensure are always built
    products = [LibraryProduct("libpcre2-$(width)", Symbol("libpcre2_$(width)")) for width in widths]

    llvm_version = v"13.0.1"

    # Dependencies that must be installed before this package can be built
    dependencies = [
        BuildDependency(PackageSpec(name="LLVMCompilerRT_jll",
                                    uuid="4e17d02c-6bf5-513e-be62-445f41c75a11",
                                    version=string(llvm_version));
                        platforms=filter(p -> sanitize(p)=="memory", platforms)),
    ]

    # Need at least GCC XXX for asm instructions on i686
    # (We could instead patch the asm instructions.)
    build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies;
                   julia_compat, preferred_gcc_version=v"5", preferred_llvm_version=llvm_version)
end
