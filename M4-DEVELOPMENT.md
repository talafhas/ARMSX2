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

This fork currently adds development helpers and documentation, and respects an
explicit macOS deployment target. The emulator engine is unchanged from the
October 3 baseline. No optimization gain or Android device result is claimed.

Keep the starting point fixed during an experiment. Compare the unmodified
October 3 baseline against the changed October 3 core with identical build
options, game checkpoint, effective settings, backend and driver. Review newer
upstream changes separately before incorporating them.

## Build preparation

The canonical reference is `.github/workflows/macos_build.yml`. The local
`tools/macos-dependencies.sh` prepares ARM64 dependencies in `deps/`, using pinned
versions and SHA-256 checks with source archives cached in `deps-build/`. Run it
once for initial setup, and again when dependency requirements change. It defaults
to Qt enabled and bundled FFmpeg disabled. Its explicit macOS 12.0 target covers
CMake and MoltenVK's Xcode builds, replacing the macOS 11.0 setting rejected by
Xcode 27. Allow substantial time and temporary storage for this setup.

From the repository root:

```sh
tools/macos-dependencies.sh
tools/macos-dev.sh build
tools/macos-dev.sh install
tools/macos-dev.sh run
tools/macos-dev.sh run "/absolute/path/game.iso"
```

`build` creates a Release ARM64 Ninja build in `build-m4/` with the macOS 12.0
target and at most four jobs. `install` builds first, stages bundled libraries,
applies and verifies a local ad-hoc signature, then atomically replaces only
`/Applications/ARMSX2.app`. It refuses installation while ARMSX2 is running and
retains the previous app in `macos-dev-recovery/` beside the checkout. `run` opens
the installed app, optionally with a game ISO. BIOS, games, saves and settings
are not changed by these helpers.

Both helpers share `build-m4/.macos-dev-operation.lock`, so dependency setup,
build, install and launch cannot overlap through them. An existing lock blocks
the operation; inspect a suspected stale lock before retrying. This cooperative
lock does not prevent launches through Finder. Finish compilation before playing
or benchmarking, and keep all compilation stopped throughout performance runs.

The default development build explicitly sets `ENABLE_TESTS=OFF` and
`ENABLE_RECOMPILER_TEST_HOOKS=OFF`. Use a separate build directory for instrumented
correctness work with `ENABLE_TESTS=ON` and, when required,
`ENABLE_RECOMPILER_TEST_HOOKS=ON`; verify runner options there. Keep benchmark
builds free of test instrumentation.

## Local verification, October 4, 2026

The pinned dependency recipe completed, and the ARM64 Release emulator build
passed on a MacBook Air M4 with Xcode 27. The installer deployed the required
libraries, normalized development-only load paths, verified the bundled ARM64
images and local signature, and replaced the existing app with a recovery copy.
The build/install/run helper was exercised, including refusal to install while
the emulator runs and refusal of overlapping helper operations.

The installed build booted the existing Racing Battle C1 Grand Prix ISO with
the existing BIOS, Metal, ARM64 recompilers, fast memory and MTVU. Per-game 8x
rendering persisted. A save state made with the official October 3 build loaded
successfully. The native benchmark application's Start and Stop & Save controls
also completed successfully against the locally built emulator.

This verifies the local development workflow and a title/demo session, not
complete gameplay compatibility or an old-versus-new performance improvement.
The controller was disconnected and audio muted during this verification.

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
notices. Keep the official October 3 reference bundle recoverable locally,
alongside the helper's previous-app recovery copy, so baseline comparisons can
restore the intended app version.

## Pinned built-in patch resource

Official macOS CI separately downloads `patches.zip` before packaging. A local
Qt build does not obtain that file automatically. Without it, the emulator
reports that built-in game patches are unavailable. The local helper now stages
the exact patch resource packaged in the official October 3 ARM64 release,
rather than downloading a rolling latest-patches archive.

The resource identities are fixed in `tools/macos-dev.sh`:

- Release URL: `https://github.com/ARMSX2/ARMSX2/releases/download/nightly-20261003/ARMSX2-nightly-20261003-9d989ca933-macOS-arm64.tar.xz`
- Release archive SHA-256: `2a418b721877a1e2268e2969d17e62d5a9d4b77d9355fcdcb27d39f51e9dc5e5`
- Exact regular tar member: `ARMSX2-iOSv2.6.0.app/Contents/Resources/patches.zip`
- Patch ZIP SHA-256: `adaf38b455c276f7ff43f989fdb58ef130c4718d39ace977f275c8e911df97cc`
- Patch ZIP size: 2,091,144 bytes; the verified reference contains 4,539 ZIP members.

`build` verifies the cached ZIP hash and all member CRCs in ignored
`build-m4/resources/nightly-20261003/`. If the ZIP is absent, it validates the
pinned release archive and reads only the exact member with Python
`tarfile.extractfile`; it never extracts release-bundle paths to disk. The
release archive is downloaded into that cache only if no local archive was
supplied and no cached archive exists. Corrupt cached inputs stop the operation
instead of being silently replaced; inspect/remove them before retrying.

To reuse an already downloaded official archive without another download:

```sh
ARMSX2_PATCH_ARCHIVE="/path/to/ARMSX2-nightly-20261003-macOS-arm64.tar.xz" \
  tools/macos-dev.sh build
```

The optional path can have any filename; its full archive hash must match the
pinned identity. It is used only when the verified ZIP is not already cached.
The same environment variable works with `install`, which builds first.

The helper copies the resource into the local build bundle, then explicitly into
the installation staging bundle before signing. Bundle verification requires the
pinned ZIP hash and valid CRCs both before atomic replacement and after
installation. Tracked `bin/resources`, runtime settings, BIOS, games and saves
are untouched. The reference archive/member/hash and CRCs were checked read-only
on October 4; packaging validation and a new runtime check remain necessary after
the next build/install.
