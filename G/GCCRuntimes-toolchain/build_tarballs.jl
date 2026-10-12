# GCC 14.2's runtime libraries as BinaryBuilder2's C toolchain installs them for a target
# (GCC_support_libraries: libgcc_s, libatomic, libgomp, ...; GCC_crt_objects: libgcc.a and
# crtbegin/crtend; libstdcxx), for a platform BinaryBuilder2 has no build of them for yet,
# such as ygglet's rr software ticks platform (`x86_64-linux-gnu-rr_softticks+1`). Built with
# BinaryBuilder2's own GCC recipe (`bootstrap/GCC`), but only these three JLLs: its `GCC`
# JLL (the cross compiler) stays the pinned one, and a universe may have its own `GCC_jll`.
#
# On a software ticks platform, the target libraries are compiled by the GCC being built,
# so they are given the software ticks plugin of the (bootstrap) toolchain explicitly.
# The target's glibc (and kernel headers) come from the toolchain universe (see
# `BinaryBuilderToolchains.use_toolchain_universe!()`), so build Glibc@2.17-toolchain first:
#   YGGLET_UNIVERSE=ygglet-toolchain scripts/bb2-build G/GCCRuntimes-toolchain
using BinaryBuilder2, BinaryBuilderToolchains
using BinaryBuilder2: JLLSource

include(joinpath(pkgdir(BinaryBuilder2), "bootstrap", "GCC", "gcc_common.jl"))

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
fi
"""
# Before `configure` (which records CFLAGS_FOR_TARGET for the target libraries)
runtimes_script = replace(script, raw"$WORKSPACE/srcdir/gcc-*/configure \\" =>
                                  softticks_script * raw"$WORKSPACE/srcdir/gcc-*/configure \\"; count=1)
@assert runtimes_script != script

function runtimes_build_spec_generator(host, platform)
    specs = gcc_build_spec_generator(host, platform)
    for spec in specs
        BinaryBuilderToolchains.use_toolchain_universe!(JLLSource[d for d in spec.dependencies if d isa JLLSource])
    end
    return specs
end

function runtimes_extract_spec_generator(build, platform)
    return filter(es -> es.jll_name != "GCC", gcc_extract_spec_generator(build, platform))
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
    extract_spec_generator = runtimes_extract_spec_generator,
    meta,
    duplicate_extraction_handling = :ignore_all,
)
