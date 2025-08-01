using BinaryBuilder, Pkg
using Base.BinaryPlatforms

const YGGDRASIL_DIR = "../.."
include(joinpath(YGGDRASIL_DIR, "fancy_toys.jl"))
include(joinpath(YGGDRASIL_DIR, "platforms", "llvm.jl"))

name = "Enzyme"
repo = "https://github.com/EnzymeAD/Enzyme.git"

auto_version = "refs/tags/v0.0.187"
version = VersionNumber(split(auto_version, "/")[end])

llvm_versions = [v"15.0.7", v"16.0.6", v"17.0.6", v"18.1.7", v"19.1.1"]

# Collection of sources required to build attr
sources = [
    GitSource(repo, "f8a676ea33805223443de4927a6b47f6d3337486"),
    ArchiveSource("https://github.com/phracker/MacOSX-SDKs/releases/download/10.15/MacOSX10.14.sdk.tar.xz",
                  "0f03869f72df8705b832910517b47dd5b79eb4e160512602f593ed243b28715f"),
]

# These are the platforms we will build for by default, unless further
# platforms are passed in on the command line
platforms = expand_cxxstring_abis(supported_platforms())
# Exclude aarch64 FreeBSD for the time being
filter!(p -> !(Sys.isfreebsd(p) && arch(p) == "aarch64"), platforms)

# Disable riscv for now
platforms = filter!(p -> arch(p) != "riscv64", platforms)

# Bash recipe for building across all platforms
script = raw"""
cd Enzyme

if [[ "${bb_full_target}" == x86_64-apple-darwin*llvm_version+15* ]] || [[ "${bb_full_target}" == x86_64-apple-darwin*llvm_version+16* ]]; then
    # LLVM 15 requires macOS SDK 10.14.
    pushd $WORKSPACE/srcdir/MacOSX10.*.sdk
    rm -rf /opt/${target}/${target}/sys-root/System
    cp -ra usr/* "/opt/${target}/${target}/sys-root/usr/."
    cp -ra System "/opt/${target}/${target}/sys-root/."
    export MACOSX_DEPLOYMENT_TARGET=10.14
    popd
fi

# 1. Build HOST
NATIVE_CMAKE_FLAGS=()
NATIVE_CMAKE_FLAGS+=(-DENZYME_CLANG=ON)
NATIVE_CMAKE_FLAGS+=(-DCMAKE_BUILD_TYPE=RelWithDebInfo)
NATIVE_CMAKE_FLAGS+=(-DCMAKE_CROSSCOMPILING:BOOL=OFF)
# Install things into $host_prefix
NATIVE_CMAKE_FLAGS+=(-DCMAKE_TOOLCHAIN_FILE=${CMAKE_HOST_TOOLCHAIN})
NATIVE_CMAKE_FLAGS+=(-DCMAKE_INSTALL_PREFIX=${host_prefix})
# Tell CMake where LLVM is
NATIVE_CMAKE_FLAGS+=(-DLLVM_DIR="${host_prefix}/lib/cmake/llvm")
NATIVE_CMAKE_FLAGS+=(-DBC_LOAD_FLAGS="-target ${target} --sysroot=/opt/${target}/${target}/sys-root --gcc-toolchain=/opt/${target}")
if [[ "${target}" == *mingw* ]]; then
    NATIVE_CMAKE_FLAGS+=(-DCMAKE_CPP_FLAGS=-pthread)
    NATIVE_CMAKE_FLAGS+=(-DCMAKE_C_FLAGS=-pthread)
fi

cmake -B build-native -S enzyme -GNinja "${NATIVE_CMAKE_FLAGS[@]}"

# Only build blasheaders and tblgen
ninja -C build-native -j ${nproc} blasheaders enzyme-tblgen
# 2. Cross-compile
CMAKE_FLAGS=()
CMAKE_FLAGS+=(-DENZYME_EXTERNAL_SHARED_LIB=ON)
CMAKE_FLAGS+=(-DBC_LOAD_HEADER=`pwd`/build-native/BCLoad/gsl/blas_headers.h)
CMAKE_FLAGS+=(-DEnzyme_TABLEGEN=`pwd`/build-native/tools/enzyme-tblgen/enzyme-tblgen)
CMAKE_FLAGS+=(-DEnzyme_TABLEGEN_EXE=`pwd`/build-native/tools/enzyme-tblgen/enzyme-tblgen)
CMAKE_FLAGS+=(-DENZYME_CLANG=OFF)
# RelWithDebInfo for decent performance, with debugability
CMAKE_FLAGS+=(-DCMAKE_BUILD_TYPE=RelWithDebInfo)
# Install things into $prefix
CMAKE_FLAGS+=(-DCMAKE_INSTALL_PREFIX=${prefix})
# Explicitly use our cmake toolchain file and tell CMake we're cross-compiling
if [[ "${target}" == *mingw* && "${bb_full_target}" == *llvm_version+16* ]]; then
    CMAKE_FLAGS+=(-DCMAKE_TOOLCHAIN_FILE=${CMAKE_TARGET_TOOLCHAIN%.*}_clang.cmake)
else
    CMAKE_FLAGS+=(-DCMAKE_TOOLCHAIN_FILE=${CMAKE_TARGET_TOOLCHAIN})
fi
CMAKE_FLAGS+=(-DCMAKE_CROSSCOMPILING:BOOL=ON)
# Tell CMake where LLVM is
CMAKE_FLAGS+=(-DLLVM_DIR="${prefix}/lib/cmake/llvm")
# Force linking against shared lib
CMAKE_FLAGS+=(-DLLVM_LINK_LLVM_DYLIB=ON)
# Build the library
CMAKE_FLAGS+=(-DBUILD_SHARED_LIBS=ON)

if [[ "${bb_full_target}" == x86_64-apple-darwin*llvm_version+15* ]] || [[ "${bb_full_target}" == x86_64-apple-darwin*llvm_version+16* ]]; then
if [[ "${target}" == x86_64-apple* ]]; then
  CMAKE_FLAGS+=(-DCMAKE_OSX_DEPLOYMENT_TARGET:STRING=10.14)
fi
else
if [[ "${target}" == x86_64-apple* ]]; then
  CMAKE_FLAGS+=(-DCMAKE_OSX_DEPLOYMENT_TARGET:STRING=10.12)
fi
fi
if [[ "${target}" == *mingw* ]]; then
    CMAKE_FLAGS+=(-DCMAKE_CPP_FLAGS=-pthread)
    CMAKE_FLAGS+=(-DCMAKE_C_FLAGS=-pthread)
    CMAKE_FLAGS+=(-DCMAKE_SHARED_LINKER_FLAGS=-pthread)
    CMAKE_FLAGS+=(-DCMAKE_EXE_LINKER_FLAGS=-pthread)
fi

echo ${CMAKE_FLAGS[@]}
cmake -B build -S enzyme -GNinja ${CMAKE_FLAGS[@]}

ninja -C build -j ${nproc} install
"""

augment_platform_block = """
    using Base.BinaryPlatforms
    $(LLVM.augment)
    function augment_platform!(platform::Platform)
        augment_llvm!(platform)
    end"""

# determine exactly which tarballs we should build
builds = []
for llvm_version in llvm_versions, llvm_assertions in (false, true)
    if llvm_version == v"11.0.1" && llvm_assertions
        continue # Does not have Clang available
    end
    # Dependencies that must be installed before this package can be built
    llvm_name = llvm_assertions ? "LLVM_full_assert_jll" : "LLVM_full_jll"
    dependencies = [
        HostBuildDependency(PackageSpec(name=llvm_name, version=llvm_version)),
        BuildDependency(PackageSpec(name=llvm_name, version=llvm_version))
    ]

    # The products that we will ensure are always built
    products = Product[
        LibraryProduct(["libEnzyme-$(llvm_version.major)", "libEnzyme"], :libEnzyme, dont_dlopen=true),
        LibraryProduct(["libEnzymeBCLoad-$(llvm_version.major)", "libEnzymeBCLoad"], :libEnzymeBCLoad, dont_dlopen=true),
    ]

    if llvm_version >= v"15"
        # We don't build LLVM 15 for i686-linux-musl.
        filter!(p -> !(arch(p) == "i686" && libc(p) == "musl"), platforms)
    end
    if llvm_version >= v"17"
        # Windows is broken for LLVM16_jll see https://github.com/JuliaPackaging/Yggdrasil/pull/8017#issuecomment-1930838052
        filter!(p -> !(os(p) == "windows"), platforms)
    end
    if llvm_version >= v"17" && llvm_assertions
        # Windows is broken for LLVM16_jll see https://github.com/JuliaPackaging/Yggdrasil/pull/8017#issuecomment-1930838052
        filter!(p -> !Sys.isapple(p), platforms)
    end 
    for platform in platforms
        augmented_platform = deepcopy(platform)
        augmented_platform[LLVM.platform_name] = LLVM.platform(llvm_version, llvm_assertions)
        gcc_version = llvm_version > v"15" ? v"10" : v"8"
        should_build_platform(triplet(augmented_platform)) || continue
        push!(builds, (;
            dependencies, products,
            platforms=[augmented_platform],
            gcc_version,
        ))
    end
end

# don't allow `build_tarballs` to override platform selection based on ARGS.
# we handle that ourselves by calling `should_build_platform`
non_platform_ARGS = filter(arg -> startswith(arg, "--"), ARGS)

# `--register` should only be passed to the latest `build_tarballs` invocation
non_reg_ARGS = filter(arg -> arg != "--register", non_platform_ARGS)

for (i,build) in enumerate(builds)
    build_tarballs(i == lastindex(builds) ? non_platform_ARGS : non_reg_ARGS,
                   name, version, sources, script,
                   build.platforms, build.products, build.dependencies;
                   preferred_gcc_version=build.gcc_version, julia_compat="1.10",
                   augment_platform_block, lazy_artifacts=true) # drop when julia_compat >= 1.7
end
