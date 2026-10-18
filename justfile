# Strata (Intel Arc / SYCL) on NixOS.
#
# Unlike upstream's ./setup.sh this uses no Docker: the engine is the Nix build
# (`just build`) and `just checkout` points the pinned Strata source at it.
# Everything else stays upstream's own flow - uv builds the .venv, models
# download from Hugging Face, server_intel.py spawns the engine. `just help`.
#
# Pick your GPU for the build: `just build` (Arc B-series), `just build-b70`
# (Arc Pro B70), `just build-a` (Arc A-series / Alchemist). AOT code is
# device-specific, so build for the card you will run.
#
# Run these from a `nix develop` shell.

# List the tasks (this file's `just --list`).
default:
    @just --list

# Explain the workflow, in order.
help:
    @echo "Strata (Intel Arc / SYCL) on NixOS - workflow:"
    @echo
    @echo "  1. build for your GPU:"
    @echo "       just build        # Arc B-series (B580 / B570 / Pro B60, BMG-G21)"
    @echo "       just build-b70    # Arc Pro B70 (BMG-G31)"
    @echo "       just build-a      # Arc A-series / Alchemist (JIT/SPIR-V)"
    @echo "  2. just checkout      # ./strata = pinned source + engine from your last build"
    @echo "  3. cd strata && ./setup.sh --backend sycl  . . . etc"
    @echo "                        # upstream's installer: uv venv, model, serve"
    @echo
    @echo "  just reset            # re-pin ./strata (drops .venv, packs, configs)"
    @echo "                        # needs ./result (your last just build*)"
    @echo
    @echo "Details and NixOS notes: README.md"

# Build for Arc B-series (B580 / B570 / Pro B60, BMG-G21). Default.
build:
    nix build .#strata-sycl-bmg-g21

# Build for Arc Pro B70 (BMG-G31).
build-b70:
    nix build .#strata-sycl-bmg-g31

# Build for Arc A-series / Alchemist (JIT/SPIR-V).
build-a:
    nix build .#strata-sycl-jit

# Create ./strata using the engine from your last `just build*` (./result).
checkout:
    strata-checkout --engine "$PWD/result/bin/strata"

# Re-pin ./strata to the pinned source, linking the engine from ./result
# (your last `just build*`); fails when there is none.
# Reset ./strata to the pinned source (drops .venv, packs, configs).
reset:
    strata-checkout --force --engine "$PWD/result/bin/strata"
