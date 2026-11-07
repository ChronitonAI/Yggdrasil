using BinaryBuilder
using Pkg
using BinaryBuilderBase: sanitize

name = "OpenLibm"
version = v"0.8.8"
sources = [
    GitSource("https://github.com/JuliaMath/openlibm.git",
              "5fe399749f9276eaa0b8403e507470da05cbbb3f"),
    DirectorySource("./bundled"),
]

script = raw"""
# Enter the funzone
cd ${WORKSPACE}/srcdir/openlibm*

# rr software ticks for the x86-64 assembly (amd64/*.S): a tick at every ENTRY and once per
# round of the fprem/fprem1 loops (after fstsw), which the compiler's ticks plugin cannot add
# to assembly. Only where the compiler predefines __RR_SOFTTICKS__ (the plugin, on the
# rr_softticks platforms); elsewhere the objects are byte-identical.
atomic_patch -p1 ${WORKSPACE}/srcdir/patches/openlibm-rr-softticks.patch

# Install into output
flags=("prefix=${prefix}")

# Build ARCH from ${target}
flags+=("ARCH=${target%-*-*}")

# OpenLibm build system doesn't recognize our windows cross compilers properly
if [[ ${target} == *mingw* ]]; then
    flags+=("OS=WINNT")
fi

if [[ ${bb_full_target} == *-sanitize+memory* ]]; then
    # Install msan runtime (for clang)
    cp -rL ${libdir}/linux/* /opt/x86_64-linux-musl/lib/clang/*/lib/linux/
fi

# Add `CC` override, since OpenLibm seems to think it knows best:
flags+=("CC=$CC")

# Build the library
make "${flags[@]}" -j${nproc}

# rr_softticks: fail the build if the software ticks did not land, which it would not notice
# otherwise (the patch is a no-op without __RR_SOFTTICKS__, and a hunk can apply in the wrong
# place after a version bump): every amd64/*.S object ticks at its entry, and the fprem/fprem1
# loops' (fmod*, remainder*, remquo*) once more. Only amd64's assembly has ticks: another
# architecture's (i387/*.S) must not be built here (aarch64 has none).
if [[ "${bb_full_target}" == *rr_softticks* ]]; then
    # The software ticks (rr's x86-64 sequence of ABI version 1: testb $0x80,0x70001807;
    # jne; decq 0x70001800; jne; int3) in an object's code
    count_ticks() {
        local d
        d=$(${OBJDUMP:-objdump} -d --no-show-raw-insn "$1") || return 1
        awk '{ sub(/^ *[0-9a-f]+:[ \t]+/, ""); gsub(/[ \t]+/, " "); gsub(/, /, ","); sub(/ $/, "") }
             /^testb \$-?0x80,0x70001807$/ { s = 1; next }
             s == 1 && /^jne / { s = 2; next }
             s == 2 && /^decq 0x70001800$/ { s = 3; next }
             s == 3 && /^jne / { s = 4; next }
             s == 4 && /^int3$/ { n++ }
             { s = 0 }
             END { print n + 0 }' <<< "${d}"
    }
    asm_objs=($(find . -name '*.S.o' | sort))
    if [[ "${target}" != x86_64-* ]]; then
        if (( ${#asm_objs[@]} )); then
            echo "OpenLibm: only the amd64 assembly has software ticks, not ${asm_objs[*]}" >&2
            exit 1
        fi
    elif (( ${#asm_objs[@]} == 0 )); then
        echo "OpenLibm: no amd64 assembly objects (*.S.o) to check" >&2
        exit 1
    fi
    for o in "${asm_objs[@]}"; do
        case "${o}" in
            ./amd64/e_fmod*|./amd64/e_remainder*|./amd64/s_remquo*) want=2 ;;
            ./amd64/*) want=1 ;;
            *) echo "OpenLibm: ${o}: assembly without software ticks" >&2; exit 1 ;;
        esac
        n=$(count_ticks "${o}") || exit 1
        if [[ "${n}" != "${want}" ]]; then
            echo "OpenLibm: ${o} has ${n} software ticks, not ${want}" >&2
            exit 1
        fi
    done
fi

# Install the library
make "${flags[@]}" install

install_license ./LICENSE.md
"""

# We enable experimental platforms as this is a core Julia dependency
platforms = supported_platforms()
push!(platforms, Platform("x86_64", "linux"; sanitize="memory"))

products = [
    LibraryProduct("libopenlibm", :libopenlibm),
]

llvm_version = v"13.0.1"
dependencies = [
    BuildDependency(PackageSpec(; name="LLVMCompilerRT_jll", uuid="4e17d02c-6bf5-513e-be62-445f41c75a11", version=string(llvm_version)); platforms=filter(p -> sanitize(p)=="memory", platforms)),
]

# Build the tarballs, and possibly a `build.jl` as well
build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies;
               lock_microarchitecture=false,
               julia_compat="1.6",
               preferred_llvm_version=llvm_version,
               preferred_gcc_version=v"8")
