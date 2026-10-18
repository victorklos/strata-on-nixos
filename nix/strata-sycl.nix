{
  lib,
  cmake,
  ninja,
  git,
  makeWrapper,
  level-zero,
  intel-oneapi-toolkit,
  intel-compute-runtime,
  intel-graphics-compiler,

  # flake inputs
  strata,
  llama-cpp,

  # AOT device for the GPU code. bmg-g21 covers the Arc B580/B570/Pro B60
  # (BMG-G21), bmg-g31 the Arc Pro B70. `null` selects a JIT/SPIR-V build (the
  # Alchemist / A-series path). See docs/INTEL_ARC.md.
  aot ? "bmg-g21",
}:

let
  runtimeEnv = import ./runtime-env.nix;

  # The port's own project() line carries the version (sycl/CMakeLists.txt reads
  # it back out of the top-level CMakeLists.txt).  Match per line: a single
  # `.*project...` builtins.match backtracks over the whole file and overflows.
  version =
    let
      lines = lib.splitString "\n" (builtins.readFile "${strata}/CMakeLists.txt");
      hit = lib.findFirst (l: builtins.match "project\\(strata VERSION.*" l != null) null lines;
      m = if hit == null then null else builtins.match "project\\(strata VERSION ([0-9.]+).*" hit;
    in
    if m == null then "0.0.0" else builtins.head m;
in
intel-oneapi-toolkit.stdenv.mkDerivation (finalAttrs: {
  pname = "strata-sycl";
  inherit version;

  src = strata;

  nativeBuildInputs = [
    cmake
    ninja
    git
    makeWrapper

    # Provides bin/ocloc, which the AOT build (-fsycl-targets=spir64_gen) needs.
    intel-compute-runtime

    # ocloc dlopens libigc.so.2, but nixpkgs' intel-compute-runtime only sets an
    # rpath on libigdrcl.so (not on libocloc.so/ocloc), so put IGC's lib on the
    # build-time loader path.
    intel-graphics-compiler
  ];
  buildInputs = [
    intel-oneapi-toolkit
    level-zero
  ];

  # nixpkgs' default hardening (-D_FORTIFY_SOURCE=3) fortifies GPU code as well:
  # the __CLANG_OFFLOAD_BUNDLE__sycl-spir64_gen section of an engine built with it
  # carries 537 __memcpy_chk references, and the device linker has no glibc to
  # resolve them against:
  #   Module <0x82cb0360>:  Unresolved Symbol <__memcpy_chk>
  # The engine then throws at its first prefill (sycl/src/prefill/prefill.cpp:4678),
  # caught by the server.  Without fortify the device bundle carries none of those
  # references.  Note icx defines _FORTIFY_SOURCE 3 too, so the flag is removed by
  # NIX_HARDENING_ENABLE, not by passing -U_FORTIFY_SOURCE.
  hardeningDisable = [
    "fortify"
    "fortify3"
  ];

  # ONEAPI_ROOT / CC / CXX come from intel-oneapi-toolkit.stdenv (its
  # nix-support/setup-hook); -qmkl additionally wants MKLROOT, and the toolkit
  # nests oneMKL under <year>.<major>/mkl/latest.
  preConfigure = ''
    export ONEAPI_ROOT="${intel-oneapi-toolkit}"
    export LD_LIBRARY_PATH="${
      lib.makeLibraryPath [ intel-graphics-compiler ]
    }''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    for d in "${intel-oneapi-toolkit}"/mkl/latest "${intel-oneapi-toolkit}"/*/mkl/latest; do
      if [ -d "$d" ]; then
        export MKLROOT="$d"
        break
      fi
    done
    echo "MKLROOT=''${MKLROOT:-<unset>}"
    echo "ONEAPI_ROOT=$ONEAPI_ROOT"
  '';

  # Configure the port's own project directly (as sycl/tools/build.sh does), so
  # the engine lands at build-sycl/strata rather than build-sycl/sycl/strata.
  configurePhase = ''
    runHook preConfigure
    cmake -S sycl -B build-sycl -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER=icx \
      -DCMAKE_CXX_COMPILER=icpx \
      -DSTRATA_GGML_DIR=${llama-cpp} \
      ${lib.optionalString (aot != null) "-DSTRATA_SYCL_AOT=${aot}"} \
      -DSTRATA_SYCL_PARITY=OFF
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    cmake --build build-sycl -j"''${NIX_BUILD_CORES:-1}" --target strata
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 build-sycl/strata "$out/bin/strata"
    runHook postInstall
  '';

  # Bake the doc's "Without Docker" environment into the binary.  rpath already
  # covers the toolkit / oneMKL / Level Zero loader; the intel-compute-runtime
  # libs are added for the NEO driver, and LD_LIBRARY_PATH lets a user point at
  # a system NEO install too.
  postFixup = ''
    wrapProgram "$out/bin/strata" \
      --prefix LD_LIBRARY_PATH : "${
        lib.makeLibraryPath [
          level-zero
          intel-compute-runtime
        ]
      }" \
      ${lib.concatStringsSep " " (
        lib.mapAttrsToList (k: v: "--set ${k} ${lib.escapeShellArg v}") runtimeEnv
      )}
  '';

  meta = {
    description = "Strata for Intel Arc (SYCL) engine (experimental community port)";
    homepage = "https://github.com/Niko1221/Strata";
    longDescription = ''
      The sycl/ port of the Strata engine, built with the Intel oneAPI DPC++
      compiler and oneMKL against the nixpkgs intel-oneapi-toolkit.  GPU code is
      AOT-compiled for bmg-g21 by default (Arc B580/B570/Pro B60).
    '';
    platforms = [ "x86_64-linux" ];
    # The engine is MIT (upstream LICENSE); only its build toolchain
    # (intel-oneapi-toolkit) is unfree (intel-eula/issl).
    license = lib.licenses.mit;
    mainProgram = "strata";
  };
})
