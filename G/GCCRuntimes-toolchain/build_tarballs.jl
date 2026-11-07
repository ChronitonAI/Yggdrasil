# GCC 14.2 as BinaryBuilder2's C toolchain installs it for a target (GCC: the compilers,
# gcc, g++ and gfortran; GCC_support_libraries: libgcc_s, libgfortran, libquadmath, libgomp,
# ...; GCC_crt_objects: libgcc.a, crtbegin/crtend and gfortran's intrinsic modules;
# libstdcxx), for a platform BinaryBuilder2 has no build of them for yet, such as ygglet's
# rr software ticks platform (`x86_64-linux-gnu-rr_softticks+1`). Built with BinaryBuilder2's
# own GCC recipe (`bootstrap/GCC`), with C, C++ and Fortran. All four JLLs replace the pinned
# ones in builds that use this toolchain universe (`use_toolchain_universe!()`): its GCC_jll
# is the cross compiler `x86_64-linux-gnu => x86_64-linux-gnu-rr_softticks+1`, the same GCC
# as the pinned one plus gfortran, which the pinned one does not have.
#
# On a software ticks platform, the target libraries are compiled by the GCC being built,
# so they are given the software ticks plugin of the (bootstrap) toolchain explicitly, the
# Fortran ones (libgfortran's, libgomp's) too: GCC passes no FCFLAGS_FOR_TARGET to them, but
# their `configure` takes FCFLAGS from the environment.
# The target's glibc (and kernel headers) come from the toolchain universe (see
# `BinaryBuilderToolchains.use_toolchain_universe!()`), so build Glibc@2.17-toolchain first
# (the platform is the triplet of the `CrossPlatform` below):
#   YGGLET_UNIVERSE=ygglet-toolchain scripts/bb2-build G/GCCRuntimes-toolchain \
#       x86_64-linux-gnu-target_arch+x86_64-target_libc+glibc-target_os+linux-target_rr_softticks+1
using BinaryBuilder2, BinaryBuilderToolchains
using BinaryBuilder2: JLLSource

include(joinpath(pkgdir(BinaryBuilder2), "bootstrap", "GCC", "gcc_common.jl"))
# Needs BinaryBuilder2's GCC recipe with Fortran (`gcc_languages()`): an older one builds a GCC_jll
# without gfortran, which would replace the pinned one in the universe all the same
isdefined(@__MODULE__, :gcc_languages) && "fortran" ∈ gcc_default_languages ||
    error("BinaryBuilder2 at $(pkgdir(BinaryBuilder2)) builds GCC without Fortran")

version = v"14.2.0"

softticks_script = raw"""
if [[ "${bb_full_target}" == *rr_softticks* ]]; then
    plugin="$(dirname "$(dirname "$(realpath "$(which "${TARGET_CC}")")")")/softticks/lib/softticks_gcc.so"
    if [[ ! -f "${plugin}" ]]; then
        echo "no software ticks plugin at ${plugin}" >&2
        exit 1
    fi
    export CFLAGS_FOR_TARGET="-g -O2 -fplugin=${plugin}"
    export CXXFLAGS_FOR_TARGET="-g -O2 -fplugin=${plugin}"
    export FCFLAGS="-g -O2 -fplugin=${plugin}"
fi
"""
# Before `configure` (which records CFLAGS_FOR_TARGET for the target libraries)
runtimes_script = replace(script, raw"$WORKSPACE/srcdir/gcc-*/configure \\" =>
                                  softticks_script * raw"$WORKSPACE/srcdir/gcc-*/configure \\"; count=1)
@assert runtimes_script != script

function runtimes_build_spec_generator(host, platform)
    specs = gcc_build_spec_generator(host, platform)
    # (It replaces the `JLLSource`s it swaps, in the vector it is given)
    for spec in specs, (idx, dep) in enumerate(spec.dependencies)
        if dep isa JLLSource
            spec.dependencies[idx] = only(BinaryBuilderToolchains.use_toolchain_universe!(JLLSource[dep]))
        end
    end
    return specs
end

build_tarballs(;
    src_name = "GCC",
    src_version = version,
    sources = [
        gcc_version_sources[version]...,
        DirectorySource(joinpath(pkgdir(BinaryBuilder2), "bootstrap", "GCC", "patches-v$(version)"); follow_symlinks=true, target="patches"),
    ],
    script = runtimes_script,
    platforms = [CrossPlatform(Platform("x86_64", "linux") => Platform("x86_64", "linux"; rr_softticks="1"))],
    products = [
        FileProduct("bin", :bindir),
    ],
    build_spec_generator = runtimes_build_spec_generator,
    extract_spec_generator = gcc_extract_spec_generator,
    meta,
    duplicate_extraction_handling = :ignore_all,
)
