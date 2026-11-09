# Note that this script can accept some limited command-line arguments, run
# `julia build_tarballs.jl --help` to see a usage message.
#
# This package repackages the `openssl` CLI executable from OpenSSL_jll.
#
# Background: Starting with Julia 1.12, OpenSSL_jll became a standard library
# with the `openssl` executable removed to minimize the standard library footprint.
# This separate package provides the CLI tool for users who need it.
#
# Rationale: OpenSSL's build system does not support building the CLI application
# separately from the libraries. Since OpenSSL builds are time-consuming
# (typically several minutes even on modern hardware), and OpenSSL_jll already
# provides a complete build including the executable, we simply extract and
# repackage the CLI tool rather than rebuilding everything from source.
using BinaryBuilder

name = "OpenSSL_CLI"
version = v"3.5.9"

# No sources needed - we're repackaging from OpenSSL_jll
sources = []

script = raw"""
# Copy the openssl executable from OpenSSL_jll. Through a temporary copy: BinaryBuilder
# symlinks the dependency into the prefix (install replaces the link), BinaryBuilder2 deploys
# a copy or a hard link of it, which install refuses to copy onto itself.
cp "${bindir}/openssl${exeext}" "${WORKSPACE}/openssl${exeext}"
install -Dvm 755 "${WORKSPACE}/openssl${exeext}" "${bindir}/openssl${exeext}"

# Install the license from OpenSSL_jll
install_license ${prefix}/share/licenses/OpenSSL/LICENSE*
"""

platforms = supported_platforms()

products = [
    ExecutableProduct("openssl", :openssl),
]

# ygglet (BinaryBuilder2, rr_softticks platforms) numbers its OpenSSL_jll builds past the
# registered versions (3.5.9 becomes 3.5.10, ...), so an exact compat cannot be met there:
# any 3.5 release from 3.5.9 on.
openssl_compat = if any(contains("rr_softticks"), ARGS)
    "~$(version.major).$(version.minor).$(version.patch)"
else
    "=$(version.major).$(version.minor).$(version.patch)"
end

dependencies = [
    Dependency("OpenSSL_jll"; compat=openssl_compat),
]

build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies;
               julia_compat="1.6")
