# Retroid development fork

This fork develops shared PS2 emulator improvements for the Retroid Pocket 6,
using an Apple Silicon Mac for initial development and correctness experiments.

## Fixed starting point

- Upstream: https://github.com/ARMSX2/ARMSX2
- Fork: https://github.com/talafhas/ARMSX2
- Development branch: `retroid-development`
- Upstream release: `nightly-20261003`
- Exact upstream commit: `9d989ca933a85bb2f1d111fd3b9e5742ac7d2fbe`
- Baseline tag: `baseline/upstream-nightly-20261003`
- Earlier reference tag: `baseline/installed-nightly-20260930`

The initial fork changes only development documentation and local-tool ignore
rules. The emulator engine is unchanged from the October 3 baseline. No speed
gain, successful local build or Android device result is claimed yet.

Keep the starting point fixed during an experiment. Compare the unmodified
October 3 baseline against the changed October 3 core with identical build
options, game checkpoint, effective settings, backend and driver. Review newer
upstream changes separately before incorporating them.

## Build preparation

The canonical Mac recipe is `.github/workflows/macos_build.yml`, with dependencies
built by `.github/workflows/scripts/macos/build-dependencies-universal.sh`.
Dependency archives in `deps-build/` are cached and verified. The upstream
ARM-only slice recipe needs compatibility review before use; compilers and
archives alone do not establish that build dependencies are installed.

The universal dependency script builds both ARM64 and Intel libraries. Allow
for substantial time and temporary storage, retain dependency versions and
SHA-256 checks, and keep compilation separate from performance runs.

Once dependencies are installed in `deps/`, the upstream ARM64 release flags are:

```sh
cmake -S . -B build-m4 -DCMAKE_PREFIX_PATH="$PWD/deps" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DDISABLE_ADVANCE_SIMD=ON -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  -DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON
cmake --build build-m4 --parallel 4
```

These commands are a build recipe, not a verified result. Configure regression
tests explicitly with `ENABLE_TESTS=ON`; recompiler test hooks and runner options
need their own configuration checks. Choose release benchmark builds separately
from instrumented correctness builds.

## First engineering milestone

1. Build and validate an unchanged baseline.
2. Confirm runtime settings, resolution, backend/driver and recording overhead.
3. Reproduce one shared synchronization, save, disc-access or graphics-readback
   problem before implementing a narrowly scoped correction.
4. Retain relevant regression tests and repeated before/after measurements.

Apple M4 measurements can validate a local experiment. They cannot establish
Adreno driver behavior, Android lifecycle correctness or sustained handheld
performance. Record Pocket 6 results only after real-device validation.

Keep firmware, games, captures containing game data, saves and personal runtime
configuration outside tracked source. Preserve the upstream GPL license and
notices. Do not replace the installed reference app while establishing baselines.
