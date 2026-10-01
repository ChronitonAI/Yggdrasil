# Bash recipe for building across all platforms
script = raw"""
cd $WORKSPACE/srcdir/openssl-*/

# This build system does not like llvm-ranlib
if [[ ${target} == *darwin* ]]; then
    export RANLIB=/opt/${target}/bin/${target}-ranlib
fi

# Manual translation of BB $target to Configure-target, see `./Configure --help`
function translate_target()
{
    if [[ ${target} == x86_64-linux* ]]; then
        echo linux-x86_64
    elif [[ ${target} == i686-linux* ]]; then
        echo linux-x86
    elif [[ ${target} == arm-linux* ]]; then
        echo linux-armv4
    elif [[ ${target} == aarch64-linux* ]]; then
        echo linux-aarch64
    elif [[ ${target} == powerpc64le-linux* ]]; then
        echo linux-ppc64le
    elif [[ ${target} == x86_64-apple-darwin* ]]; then
        echo darwin64-x86_64-cc
    elif [[ ${target} == aarch64-apple-darwin* ]]; then
        echo darwin64-arm64-cc
    elif [[ ${target} == x86_64-unknown-freebsd* ]]; then
        echo BSD-x86_64
    elif [[ ${target} == aarch64-unknown-freebsd* ]]; then
        echo BSD-aarch64
    elif [[ ${target} == x86_64*mingw* ]]; then
        echo mingw64
    elif [[ ${target} == i686*mingw* ]]; then
        echo mingw
    else
        if [[ ${nbits} == 32 ]]; then
            echo linux-generic32
        else
            echo linux-generic64
        fi
    fi
}

if [[ ${target} == *mingw* ]]; then
   # Our mingw32 headers are too old; we need to define `SIO_UDP_NETRESET` manually
   # (This constant is `0x80000000 | 0x18000000 | 15`.)
   export CFLAGS='-DSIO_UDP_NETRESET=2550136847UL'
fi

extra_args=()
if ! perl -MPod::Usage -e 1 2>/dev/null; then
    # BinaryBuilder2's Perl_jll lacks Pod::Usage, which configdata.pm loads (only to print
    # its own --help): a stub.
    mkdir -p ${WORKSPACE}/perl5/Pod
    printf 'package Pod::Usage;\nuse Exporter "import";\nour @EXPORT = qw(pod2usage);\nsub pod2usage { exit 0 }\n1;\n' > ${WORKSPACE}/perl5/Pod/Usage.pm
    export PERL5LIB="${WORKSPACE}/perl5${PERL5LIB:+:${PERL5LIB}}"
fi
if [[ "${bb_full_target}" == *rr_softticks* ]]; then
    # ygglet images: the system OpenSSL, whose configuration and CA certificates live in
    # /etc/ssl (the default would be /usr/local/ssl).
    extra_args+=(--openssldir=/etc/ssl)
fi
./Configure shared --prefix=$prefix --libdir=${libdir} "${extra_args[@]}" $(translate_target)
make -j${nproc}
make install_sw

# Manually delete static libraries, not possible to skip them:
# <https://github.com/openssl/openssl/issues/8823>.
rm -v ${libdir}/lib{crypto,ssl}.a
"""

# These are the platforms we will build for by default, unless further
# platforms are passed in on the command line
platforms = supported_platforms()

# Dependencies that must be installed before this package can be built
dependencies = Dependency[
]
