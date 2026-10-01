# pexpect and ptyprocess (pure Python) for the Python of ygglet images: rr's test suite
# drives gdb with them.
using BinaryBuilder, Pkg

name = "PythonPexpect"
version = v"4.9.0"

sources = [
    ArchiveSource("https://files.pythonhosted.org/packages/source/p/pexpect/pexpect-4.9.0.tar.gz",
                  "ee7d41123f3c9911050ea2c2dac107568dc43b2d3b0c7557a33212c398ead30f"),
    ArchiveSource("https://files.pythonhosted.org/packages/source/p/ptyprocess/ptyprocess-0.7.0.tar.gz",
                  "5c5d0a3b48ceee0b48485e0c26037c0acd7d29765ca3fbb5cb3831d347423220"),
]

script = raw"""
# The site-packages of Python_jll 3.12.
site=${prefix}/lib/python3.12/site-packages
mkdir -p ${site}
cp -r ${WORKSPACE}/srcdir/pexpect-*/pexpect ${site}/
cp -r ${WORKSPACE}/srcdir/ptyprocess-*/ptyprocess ${site}/
install_license ${WORKSPACE}/srcdir/pexpect-*/LICENSE
"""

platforms = [AnyPlatform()]

products = [
    FileProduct("lib/python3.12/site-packages/pexpect/__init__.py", :pexpect),
    FileProduct("lib/python3.12/site-packages/ptyprocess/__init__.py", :ptyprocess),
]

dependencies = Dependency[]

build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies; julia_compat="1.6")
