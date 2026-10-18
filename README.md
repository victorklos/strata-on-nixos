# Strata Intel Arc (SYCL) — Nix flake

A Nix flake that builds the [Strata](https://github.com/Niko1221/Strata) engine's
experimental SYCL port (`sycl/`) for Intel Arc GPUs on NixOS, following the "Build
without Docker (Linux)" path in the upstream `docs/INTEL_ARC.md`.

The upstream instructions assume an Intel oneAPI apt/rpm install (with
`setvars.sh`). NixOS has no `setvars.sh`, so this flake wires the toolchain,
the AOT compiler, the Level Zero stack and the runtime environment explicitly.

Upstream's project expects a mutable, container-like environment, so packaging
all of it in Nix is not worth it. This flake packages what is hard to get right
on NixOS and leaves the rest to upstream's own scripts:

1. compile the strata engine for SYCL
2. patch the strata runtime so that engine is used
3. have fun

Running strata, downloading models etc. is done as usual.


## Quick start

```sh
nix develop
just build                       # Arc B-series (B580); other GPUs: just help
just checkout
cd strata && ./setup.sh --backend sycl
```

`just help` lists every recipe and prints these steps; the other build targets
are explained below.


## Build targets (which GPU?)

Each build is one `just` recipe (one flake output), targeting one GPU family:

| Recipe           | Flake output          | `aot`     | Hardware                              |
| ---------------- | --------------------- | --------- | ------------------------------------- |
| `just build`     | `strata-sycl-bmg-g21` | `bmg-g21` | Arc B580 / B570 / Pro B60 (default)   |
| `just build-b70` | `strata-sycl-bmg-g31` | `bmg-g31` | Arc Pro B70                           |
| `just build-a`   | `strata-sycl-jit`     | `null`    | Arc A-series / Alchemist (JIT/SPIR-V) |

AOT binaries are device-specific; the `jit` build runs anywhere (including
B-series) but compiles kernels on first use. `just checkout` links the engine
from the last `just build*` (`./result`), so build and checkout stay in sync.


## NixOS setup

You will need compute runtimes installed plus support for CPython. Make the
following fragment part of your config:

```nix
{ pkgs, ... }:
{
  # Required for any GPU user-space stack on NixOS.
  hardware.graphics.enable = true;

  # Intel compute and media
  hardware.graphics.extraPackages = with pkgs; [
    intel-compute-runtime
    level-zero
    vpl-gpu-rt
    intel-media-driver
  ];

  # `./setup.sh` builds its venv with `uv`, which downloads a Python built for
  # generic glibc Linux (python-build-standalone). On NixOS this needs `nix-ld`.
  programs.nix-ld.enable = true;
}
```

Finally make sure the users that will be using this are part of the `render` group.


## Running the installer (`./setup.sh --backend sycl`) without Docker

`./setup.sh` is upstream's own installer: it builds the Python environment,
downloads the model and ends up starting the server, which spawns the engine.
The flake's job is to hand it a native runner and the Nix-built engine at the
places it looks for them (see `strata-checkout` below).

`strata-checkout` (provided by the dev shell, and what `just checkout` runs)
materialises the flake's pinned Strata source into a writable `./strata`, pointing
a few things at the Nix inputs:

```text
sycl/serve/strata-sycl.sh -> native runner (upstream Docker script kept as .docker)
build-sycl-aot/strata     -> <engine from your last build>/bin/strata
build-sycl-aot/BUILD.json -> engine version, so the server can report it
third_party/llama.cpp     -> the pinned llama.cpp input (setup.py would fetch it otherwise)
```

Everything else — the `.venv` built by `uv`, the Hugging Face model download, the
configs, the serve step — stays upstream's own job; the workflow is the one from
Quick start.

The checkout is disposable state. `just checkout` refreshes an existing one (the
`.venv`, packs and configs stay put) or creates it; `just reset` recreates it
from the pinned source, dropping that state. Both take the engine from
`./result` (your last `just build*`) and fail with "build it first" when you
haven't built one, so a checkout always runs your newest engine.

Model packs live in the current directory as upstream makes lots of assumptions due
to it running containerised.


## NixOS-specific workarounds

Three workarounds are built in; they live where they bite: the run-time one
(#2) is in `nix/runtime-env.nix`, applied by the engine wrapper and by the
devShell, the build-time ones (#1 and #3) in `nix/strata-sycl.nix`. All are
harmless to keep.

### 1. `ocloc` cannot find `libigc.so.2` (build time)

The AOT step runs `ocloc` (from `intel-compute-runtime`), which `dlopen`s
`libigc.so.2`. nixpkgs only sets an rpath on `libigdrcl.so`, not on
`libocloc.so`/`ocloc`, so `ocloc` fails with:

```
Error! Loading of IGC library has failed! Filename: libigc.so.2
igc: error: gen compiler command failed with exit code 250
```

Fix: `intel-graphics-compiler` is added to the build inputs and its `lib` dir is
prepended to `LD_LIBRARY_PATH` during the build (`nix/strata-sycl.nix`); the
devShell does the same. This is harmless and can stay even after upstream is fixed.

### 2. Level Zero aborts on BMG-G21 (run time)

`intel-compute-runtime` version 26.31.x in nixpkgs sets
`requiredPreemptionSurfaceSize` to `0` for the Arc B580 (BMG-G21) and then
aborts while creating the preemption allocation:

```
Abort was called at 1205 line in file:
.../shared/source/command_stream/command_stream_receiver.cpp
```

This kills every Level Zero enumeration, so `sycl-ls`, the OpenCL ICD and the
engine all die. The upstream debug override supplies a non-zero size; `4096` is
the value BMG's capability table is supposed to carry:

```sh
NEOReadDebugKeys=1 NEO_OverrideCsrAllocationSize=4096
```

It has since carried a full request on the B580 (prefill and generation).
Remove both variables once nixpkgs ships a compute-runtime with the upstream
fix: the abort is a genuine driver bug, reproduced with a plain Level Zero
program that involves neither SYCL nor the engine.

### 3. NixOS hardening

nixpkgs enables `_FORTIFY_SOURCE=3` by default. The `__memcpy_chk` calls it
adds end up in the GPU code too, where nothing can resolve them (there is no
glibc on the device), so the engine failed with
`Unresolved Symbol <__memcpy_chk>` and died on the first prompt. Hardening is
therefore disabled for this build (`hardeningDisable` in
`nix/strata-sycl.nix`, which has the details).
