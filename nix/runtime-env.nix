# Runtime environment for the Strata Intel Arc (SYCL) engine.

# This mirrors the export list in docs/INTEL_ARC.md, "Build without Docker (Linux)":
# there is no setvars.sh on NixOS, so the wrapper (nix/strata-sycl.nix) and the
# devShell both apply these directly.

# STRATA_VERIFY_NO_HOST=1 is required on the `xe` driver (Arc B-series, which
# is what I have) whenever part of the experts are not in VRAM; on the `i915`
# A-series/Alchemist cards it must be left unset.  Override the whole set with
# `--set`/`--unset` on the wrapped binary, or edit this file for an A-series
# build.
{
  # The persistent JIT cache crashed on Xe2 during the first compile.
  SYCL_CACHE_PERSISTENT = "0";
  # Let the Level Zero sysman queries work.
  ZES_ENABLE_SYSMAN = "1";
  # Print the device plan the engine chose.
  STRATA_VERIFY_DEVICE_PLAN = "1";
  # xe cards: host-to-GPU flag stores are not visible unless NO_HOST is set.
  STRATA_VERIFY_NO_HOST = "1";

  # --- NEO/Level-Zero workaround (Arc B580, BMG-G21) ------------------------
  # intel-compute-runtime 26.31.x sets requiredPreemptionSurfaceSize to 0 for
  # this device and then aborts in
  #   CommandStreamReceiver::createPreemptionAllocation()
  # ("Abort was called at 1205 line in .../command_stream_receiver.cpp"), which
  # makes every Level Zero enumeration (and thus SYCL/sycl-ls) die.  The
  # upstream debug flag overrides the allocation with a non-zero size; 4096 is
  # the value BMG's capability table is supposed to carry.  Drop both lines once
  # nixpkgs ships a compute-runtime with the upstream "abort when preemption
  # surface size is 0" fix.
  NEOReadDebugKeys = "1";
  NEO_OverrideCsrAllocationSize = "4096";

  # For `--layer-split` across two cards, additionally set:
  #   ONEAPI_DEVICE_SELECTOR = "level_zero:*";
  #   STRATA_MIRROR_MIB = "0";
}
