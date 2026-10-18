#!/usr/bin/env bash
# strata-sycl.sh, NixOS variant: the SYCL-built engine as a drop-in `exe` for
# serve/server.py (--engine strata), without Docker.
#
# Upstream ships this path as a Docker wrapper (kept next to it as
# strata-sycl.sh.docker).  This native variant is installed by the flake's
# `strata-checkout` so that sycl/setup_intel.py - which hardcodes
# sycl/serve/strata-sycl.sh as the config's "exe" - runs the locally built (Nix)
# engine directly.
#
# setup_intel.py rewrites the config's data paths to the container's /work/<rel>
# (what the Docker wrapper mounts); here we undo that: /work/<rel> -> <root>/<rel>,
# where <root> is the folder the Docker variant would have mounted (the checkout's
# parent, or STRATA_SYCL_ROOT).  The engine (STRATA_SYCL_BIN, default
# build-sycl-aot/strata) is the Nix build, whose wrapper already carries the
# oneAPI / Level Zero runtime environment (nix/runtime-env.nix).
set -euo pipefail
here=$(cd "$(dirname "$0")/../.." && pwd)                 # the repo
root=${STRATA_SYCL_ROOT:-$(dirname "$here")}
# A run-time default the Docker image carried; setup_intel.py does not write it
# (the engine wrapper supplies the rest of the port's switches).  Exported so the
# engine, a child of this script, inherits it.
export STRATA_STAGER_THREADS="${STRATA_STAGER_THREADS:-12}"
cd "$here"
args=()
for a in "$@"; do
    args+=("${a/#\/work\//${root}/}")                     # container path -> host path
done
exec "$here/${STRATA_SYCL_BIN:-build-sycl-aot/strata}" "${args[@]}"
