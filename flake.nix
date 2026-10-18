{
  description = "Strata engine for Intel Arc (SYCL) on NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    strata = {
      url = "github:Niko1221/Strata";
      flake = false;
    };

    # NB: bump this rev in lockstep with the `strata` rev's CMakeLists.txt.
    llama-cpp = {
      url = "github:ggml-org/llama.cpp/3cf03257f219afbe7334045ff7c6a06ac68c627d";
      flake = false;
    };
  };

  outputs =
    inputs@{ self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;

      # The SYCL engine is x86_64-linux only (Intel GPU + unfree toolchain).
      system = "x86_64-linux";

      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfreePredicate = pkg: lib.getName pkg == "intel-oneapi-toolkit";
      };

      # One engine derivation per AOT (Ahead of Time) target; `null` selects the JIT/SPIR-V
      # (Arc A-series / Alchemist) build. AOT code is device-specific.
      strata-engine =
        aot:
        pkgs.callPackage ./nix/strata-sycl.nix {
          inherit (inputs) strata llama-cpp;
          inherit aot;
        };
      strata-sycl-bmg-g21 = strata-engine "bmg-g21"; # Arc B580 / B570 / Pro B60
      strata-sycl-bmg-g31 = strata-engine "bmg-g31"; # Arc Pro B70
      strata-sycl-jit = strata-engine null; # Arc A-series / Alchemist
      strata-sycl = strata-sycl-bmg-g21; # default

      # Native drop-in for sycl/serve/strata-sycl.sh
      shim = pkgs.writeTextFile {
        name = "strata-sycl.sh";
        executable = true;
        text = builtins.replaceStrings [ "#!/usr/bin/env bash" ] [ "#!${pkgs.runtimeShell}" ] (
          builtins.readFile ./nix/strata-sycl-shim.sh
        );
      };

      # The pinned and patched strata source
      strata-src = pkgs.runCommand "strata-src-${strata-sycl.version}" { } ''
        cp -r ${inputs.strata} $out
        chmod -R u+w $out
        mv "$out/sycl/serve/strata-sycl.sh" "$out/sycl/serve/strata-sycl.sh.docker"
        cp ${shim} "$out/sycl/serve/strata-sycl.sh"
        chmod +x "$out/sycl/serve/strata-sycl.sh"
        mkdir -p "$out/build-sycl-aot"
        printf '{"version":"%s","source":"local","lib_dirs":[]}\n' ${lib.escapeShellArg strata-sycl.version} \
          > "$out/build-sycl-aot/BUILD.json"
      '';

      # Copy the prepared source into a writable checkout and point it at the Nix engine,
      # so that sycl/setup_intel.py (which hardcodes sycl/serve/strata-sycl.sh as the config's
      # "exe" and build-sycl-aot/strata as the engine) uses both.
      #
      # The default engine below is baked in when this command is built, so a bare
      # `strata-checkout [--force]` links it - possibly an older one than your current
      # build.  `just checkout` and `just reset` pass --engine "$PWD/result/bin/strata"
      # (the engine from your last `just build*`) instead, so their checkout always runs
      # your newest build, and they fail when there is no ./result.
      checkout = pkgs.writeShellApplication {
        name = "strata-checkout";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          force=0
          engine=${strata-sycl}/bin/strata
          dest=""
          while [ $# -gt 0 ]; do
            case "$1" in
              --force) force=1; shift ;;
              --engine) engine="$2"; shift 2 ;;
              --engine=*) engine="''${1#--engine=}"; shift ;;
              --) shift; if [ $# -gt 0 ]; then dest="$1"; shift; fi; break ;;
              -*) echo "strata-checkout: unknown option: $1" >&2; exit 2 ;;
              *) dest="$1"; shift ;;
            esac
          done
          dest="''${dest:-''${STRATA_DIR:-$PWD/strata}}"

          if [ ! -x "$engine" ]; then
            echo "strata-checkout: engine not found or not executable: $engine" >&2
            echo "                 build it first (e.g. 'just build')." >&2
            exit 1
          fi

          if [ "$force" = 1 ] || [ ! -e "$dest/setup.sh" ]; then
            rm -rf "$dest"
            mkdir -p "$dest"
            cp -r ${strata-src}/. "$dest/"
            chmod -R u+w "$dest"
            echo "strata: copied the pinned checkout to $dest"
          else
            # Point an existing checkout at the native runner, keeping upstream's
            # Docker wrapper the first time.
            if [ ! -e "$dest/sycl/serve/strata-sycl.sh.docker" ] \
              && ! cmp -s ${strata-src}/sycl/serve/strata-sycl.sh "$dest/sycl/serve/strata-sycl.sh"; then
              mv "$dest/sycl/serve/strata-sycl.sh" "$dest/sycl/serve/strata-sycl.sh.docker"
            fi
            cp -f ${strata-src}/sycl/serve/strata-sycl.sh "$dest/sycl/serve/strata-sycl.sh"
            cp -f ${strata-src}/build-sycl-aot/BUILD.json "$dest/build-sycl-aot/BUILD.json"
            echo "strata: refreshed $dest"
          fi

          mkdir -p "$dest/build-sycl-aot"
          ln -sfn "$engine" "$dest/build-sycl-aot/strata"

          # setup.py's get_llama_cpp() wants third_party/llama.cpp (ggml +
          # gguf-py) and would otherwise download it; hand it the pinned input.
          mkdir -p "$dest/third_party"
          rm -rf "$dest/third_party/llama.cpp"
          ln -s ${inputs.llama-cpp} "$dest/third_party/llama.cpp"

          echo "        engine: build-sycl-aot/strata -> $engine"
          echo "        ggml:   third_party/llama.cpp -> ${inputs.llama-cpp}"
          echo
          echo "Next:"
          echo "  cd $dest && ./setup.sh --backend sycl"
        '';
      };

      # The wrapped icx/icpx (nixpkgs' cc-wrapper: gcc toolchain, libstdc++ and
      # glibc include paths).  The raw toolkit's compilers are what
      # `command -v icpx` finds in the shell, and without the wrapper they cannot
      # even locate <cstring> on NixOS, so any manual build in the shell (upstream's
      # sycl/tools/build.sh) fails.  Only these two names are shadowed.
      syclCompilers =
        let
          cc = pkgs.intel-oneapi-toolkit.stdenv.cc;
        in
        pkgs.runCommand "strata-sycl-compilers" { } ''
          mkdir -p "$out/bin"
          for t in icx icpx; do
            if [ ! -x "${cc}/bin/$t" ]; then
              echo "strata-sycl-compilers: no such compiler: ${cc}/bin/$t" >&2
              exit 1
            fi
            ln -s "${cc}/bin/$t" "$out/bin/$t"
          done
        '';

      # Keep the shell's runtime env identical to the packaged engine's.
      runtimeEnv = import ./nix/runtime-env.nix;
      runtimeExports = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}") runtimeEnv
      );
    in
    {
      formatter.${system} = pkgs.nixfmt-tree;

      packages.${system} = {
        inherit
          strata-sycl
          strata-sycl-bmg-g21
          strata-sycl-bmg-g31
          strata-sycl-jit
          ;
        default = strata-sycl;
      };

      checks.${system} = {
        build = strata-sycl;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages =
          with pkgs;
          [
            # wrapped icx/icpx first, so they win over the raw toolkit below
            syclCompilers
            cmake
            ninja
            git
            uv
            just
            (python3.withPackages (p: [ p.numpy ]))
            level-zero
            intel-gpu-tools
            intel-compute-runtime
            intel-graphics-compiler
            intel-oneapi-toolkit
          ]
          ++ [ checkout ];

        shellHook = ''
          export ONEAPI_ROOT="${pkgs.intel-oneapi-toolkit}"

          # -qmkl needs MKLROOT; the toolkit nests oneMKL under <year>/mkl/latest.
          for d in "$ONEAPI_ROOT"/mkl/latest "$ONEAPI_ROOT"/*/mkl/latest; do
            if [ -d "$d" ]; then export MKLROOT="$d"; break; fi
          done

          # Let a manual `ocloc`/AOT build find libigc.so.2.
          export LD_LIBRARY_PATH="${pkgs.intel-graphics-compiler}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

          # Same runtime environment the packaged engine is wrapped with.
          ${runtimeExports}

          # Point CMake at the pinned ggml instead of letting it hit the network.
          export STRATA_GGML_DIR=${inputs.llama-cpp}

          echo "Strata SYCL shell"
          echo "  icpx:    $(command -v icpx || echo 'NOT FOUND')"
          echo "  MKLROOT: $MKLROOT"

          # Python uv needs `nix-ld` as per <https://wiki.nixos.org/wiki/Python_quickstart_using_uv>
          if [ ! -e /run/current-system/sw/share/nix-ld/lib/ld.so ] && [ -z "''${NIX_LD:-}" ]; then
            echo
            echo "WARNING: nix-ld does not appear to be enabled. ./setup.sh needs it to" >&2
            echo "         run the Python that uv downloads. See README." >&2
          fi
          # setup.py also downloads, make sure uv's Python can find the certs
          export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt

          echo
          if [ -f justfile ]; then
            echo "======================================================================"
            echo "This project uses a justfile for easy command running. Type \`just\` or"
            echo "\`just help\` to get going. In case of errors, try \`nix develop\` first."
            echo "======================================================================"
          fi
        '';
      };
    };
}
