#!/bin/bash
# Native local development: build/install use Release without test-only JIT hooks.
# install builds first, deploys a private staging copy, signs it ad-hoc, and keeps
# the previous installed bundle outside the checkout. User data is never touched.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUILD="$ROOT/build-m4"
DEPS="$ROOT/deps"
APP="/Applications/ARMSX2.app"

die() { echo "macos-dev: $*" >&2; exit 1; }

check_stopped() {
	local status=0
	/usr/bin/pgrep -x ARMSX2 >/dev/null || status=$?
	case "$status" in
		0) die "Quit ARMSX2 before installing or passing a game to a new launch." ;;
		1) ;;
		*) die "Could not determine whether ARMSX2 is running." ;;
	esac
}

build_app() {
	[ "$(uname -s)" = Darwin ] || die "This helper requires macOS."
	[ "$(uname -m)" = arm64 ] || die "Run from a native ARM64 terminal."
	[ -d "$DEPS/lib" ] || die "Missing dependency prefix: $DEPS"
	command -v cmake >/dev/null || die "cmake is required."
	command -v ninja >/dev/null || die "ninja is required."
	command -v ccache >/dev/null || die "ccache is required."
	local jobs
	jobs="$(getconf _NPROCESSORS_ONLN)"
	if [ "$jobs" -gt 4 ]; then jobs=4; fi
	echo "Building Release ARM64, macOS 12.0, $jobs jobs; tests and recompiler test hooks OFF."
	cmake -S "$ROOT" -B "$BUILD" -G Ninja \
		-DCMAKE_PREFIX_PATH="$DEPS" \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
		-DDISABLE_ADVANCE_SIMD=ON \
		-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF \
		-DCMAKE_C_COMPILER_LAUNCHER=ccache \
		-DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
		-DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON \
		-DENABLE_QT_UI=ON \
		-DENABLE_QT_DEBUGGER=OFF \
		-DENABLE_TESTS=OFF \
		-DENABLE_RECOMPILER_TEST_HOOKS=OFF \
		-DSKIP_POSTPROCESS_BUNDLE=ON
	# The separate upstream postprocess target is not a dependency of pcsx2-qt.
	# install invokes the same macdeployqt -no-strip command on its staging copy.
	cmake --build "$BUILD" --target pcsx2-qt --parallel "$jobs"
	[ -x "$BUILD/pcsx2-qt/ARMSX2.app/Contents/MacOS/ARMSX2" ] ||
		die "Build did not produce the expected ARMSX2.app bundle."
}

install_app() {
	check_stopped
	[ -w /Applications ] || die "/Applications is not writable; obtain permission before installation."
	[ -x "$DEPS/bin/macdeployqt" ] || die "Missing $DEPS/bin/macdeployqt"
	[ -x /usr/bin/python3 ] || die "Xcode's Python 3 is required for atomic directory exchange."
	build_app
	# renamex_np(RENAME_SWAP) exchanges two bundle directories atomically on macOS.
	# No old-app deletion precedes deployment, signing, or the atomic exchange.
	/usr/bin/python3 - "$ROOT" "$BUILD" "$DEPS" "$APP" <<'PY'
import ctypes
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

root, build, deps, installed = map(Path, sys.argv[1:])
source = build / "pcsx2-qt/ARMSX2.app"
lock = installed.parent / ".ARMSX2-dev-install.lock"
stage_dir = None
exchanged = False
new_install = False
preserve_stage = False

def call(*args):
    subprocess.run([str(a) for a in args], check=True)

def stopped():
    result = subprocess.run(["/usr/bin/pgrep", "-x", "ARMSX2"], stdout=subprocess.DEVNULL)
    if result.returncode != 1:
        raise RuntimeError("ARMSX2 is running or its process state could not be checked; quit it first.")

libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
rename = libc.renamex_np
rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
rename.restype = ctypes.c_int

def rename_bundle(src, dst, flag):
    if rename(os.fsencode(src), os.fsencode(dst), flag) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(dst))

def normalize_development_load_paths(bundle):
    # macdeployqt bundles imports but may retain dependency-build LC_RPATHs.
    # Remove only known development-prefix paths on this private staging copy.
    # The unchanged verifier below must still resolve every import and self ID.
    bundle_root = bundle.resolve()
    development_roots = (deps.resolve(), build.resolve())
    for directory, _, files in os.walk(bundle):
        for name in files:
            image = Path(directory) / name
            if image.is_symlink():
                continue
            description = subprocess.check_output(["/usr/bin/file", "-b", str(image)], text=True)
            if "Mach-O" not in description:
                continue
            commands = subprocess.check_output(["/usr/bin/otool", "-l", str(image)], text=True)
            values = re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset \d+\)", commands)
            for value in dict.fromkeys(values):
                if not value.startswith("/"):
                    continue  # Token paths remain subject to strict verification.
                resolved = Path(value).resolve()
                if resolved.is_relative_to(bundle_root) or any(
                    resolved.is_relative_to(system) for system in (Path("/usr/lib"), Path("/System/Library"))
                ):
                    continue
                if not any(resolved.is_relative_to(prefix) for prefix in development_roots):
                    raise RuntimeError("Unexpected external RPATH in " + str(image) + ": " + value)
                print("Removing development RPATH from " + str(image.relative_to(bundle)) + ": " + value)
                call("/usr/bin/install_name_tool", "-delete_rpath", value, image)
            # MoltenVK keeps an @rpath self ID after macdeployqt rewrites its
            # consumers to bundle-relative imports. Give such a flat dylib ID
            # a contained search path without changing the ID or its imports.
            self_ids = re.findall(r"cmd LC_ID_DYLIB\s+cmdsize \d+\s+name (.*?) \(offset \d+\)", commands)
            for value in self_ids:
                if value.startswith("/") and any(
                    Path(value).resolve().is_relative_to(prefix) for prefix in development_roots
                ):
                    # macdeployqt rewrites consumers but leaves shaderc's absolute
                    # self ID. Name this staged image relative to its own location.
                    call("/usr/bin/install_name_tool", "-id", "@loader_path/" + image.name, image)
            if any(value.startswith("@rpath/") and
                   (image.parent / value[len("@rpath/"):]).resolve() == image.resolve()
                   for value in self_ids) and "@loader_path" not in values:
                call("/usr/bin/install_name_tool", "-add_rpath", "@loader_path", image)

def verify_bundle(bundle):
    bundle_root = bundle.resolve()
    executable = bundle / "Contents/MacOS/ARMSX2"
    if not executable.is_file():
        raise RuntimeError("Bundle executable is missing.")
    identity = subprocess.check_output([
        "/usr/libexec/PlistBuddy", "-c", "Print :CFBundleIdentifier",
        str(bundle / "Contents/Info.plist")], text=True).strip()
    if identity != "net.armsx2.armsx2":
        raise RuntimeError("Unexpected bundle identity: " + identity)
    # macdeployqt resolves Qt and transitive dylibs. Resolve paths and symlinks
    # before testing containment; a textual prefix is not a library boundary.
    main_commands = subprocess.check_output(["/usr/bin/otool", "-l", str(executable)], text=True)
    def rpaths(commands):
        return re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset \d+\)", commands)
    def system_path(path):
        return any(path.is_relative_to(system) for system in (Path("/usr/lib"), Path("/System/Library")))
    def contained(path):
        resolved = path.resolve()
        if not resolved.is_relative_to(bundle_root) and not system_path(resolved):
            raise RuntimeError("Load path escapes the bundle and system roots: " + str(path))
        return resolved
    def expand(value, image):
        for token, directory in (("@executable_path", executable.parent), ("@loader_path", image.parent)):
            if value == token or value.startswith(token + "/"):
                suffix = value[len(token):].lstrip("/")
                if "@" in suffix:
                    raise RuntimeError("Unsupported nested token in load path: " + value)
                return contained(directory / suffix)
        if value.startswith("/"):
            return contained(Path(value))
        raise RuntimeError("Unsupported relative load path or token: " + value)
    main_rpaths = [expand(value, executable) for value in rpaths(main_commands)]
    for directory, directories, files in os.walk(bundle):
        for name in directories:
            path = Path(directory) / name
            if path.is_symlink() and not path.resolve().is_relative_to(bundle.resolve()):
                raise RuntimeError("Bundle directory symlink escapes its directory: " + str(path))
        for name in files:
            path = Path(directory) / name
            if path.is_symlink():
                target = path.resolve()
                if not target.is_relative_to(bundle.resolve()):
                    raise RuntimeError("Bundle symlink escapes its directory: " + str(path))
                continue
            description = subprocess.check_output(["/usr/bin/file", "-b", str(path)], text=True)
            if "Mach-O" not in description:
                continue
            call("/usr/bin/lipo", "-verify_arch", "arm64", path)
            dependencies = subprocess.check_output(["/usr/bin/otool", "-L", str(path)], text=True)
            commands = subprocess.check_output(["/usr/bin/otool", "-l", str(path)], text=True)
            search_paths = main_rpaths + [expand(value, path) for value in rpaths(commands)]
            self_ids = re.findall(r"cmd LC_ID_DYLIB\s+cmdsize \d+\s+name (.*?) \(offset \d+\)", commands)
            for line in dependencies.splitlines()[1:]:
                dependency = line.strip().split(" (", 1)[0]
                if dependency.startswith("@rpath/"):
                    suffix = dependency[len("@rpath/"):]
                    if "@" in suffix:
                        raise RuntimeError("Unsupported nested token in library: " + dependency)
                    candidates = [contained(prefix / suffix) for prefix in search_paths]
                elif dependency.startswith(("@loader_path/", "@executable_path/")):
                    candidates = [expand(dependency, path)]
                elif dependency.startswith("/"):
                    candidate = contained(Path(dependency))
                    if system_path(candidate) and dependency not in self_ids:
                        # System libraries may exist only in dyld's shared cache.
                        continue
                    candidates = [candidate]
                else:
                    raise RuntimeError("Unsupported relative library name or token: " + dependency)
                if dependency in self_ids:
                    # otool -L includes a dylib's LC_ID_DYLIB as well as its imports.
                    # A bundled framework alias must resolve to this very image.
                    candidates = [candidate for candidate in candidates if candidate == path.resolve()]
                if not any(candidate.is_file() for candidate in candidates):
                    raise RuntimeError("Unresolved library or self ID: " + dependency + " in " + str(path))
    call("/usr/bin/codesign", "--verify", "--deep", "--strict", bundle)

try:
    lock.mkdir()
except FileExistsError:
    sys.exit("Another install is active, or a prior interrupted install left " + str(lock) + ". Inspect it before retrying.")

try:
    stopped()
    if installed.is_symlink() or (installed.exists() and not installed.is_dir()):
        raise RuntimeError("Refusing to replace a symlink or non-directory at " + str(installed))
    recovery_root = root.parent / "macos-dev-recovery"
    recovery_root.mkdir(exist_ok=True)
    recovery = Path(tempfile.mkdtemp(prefix=time.strftime("%Y%m%d-%H%M%S-"), dir=recovery_root))
    stage_dir = Path(tempfile.mkdtemp(prefix=".ARMSX2-dev-stage-", dir=installed.parent))
    staged = stage_dir / "ARMSX2.app"
    call("/usr/bin/ditto", source, staged)
    call(deps / "bin/macdeployqt", staged, "-no-strip")
    normalize_development_load_paths(staged)
    call("/usr/bin/codesign", "--force", "--deep", "--sign", "-", staged)
    verify_bundle(staged)
    stopped()
    # An interrupt can occur between the atomic syscall and updating our flags.
    # Keep staging until successful backup/validation or confirmed rollback.
    preserve_stage = True
    if installed.exists():
        rename_bundle(staged, installed, 0x00000002)  # RENAME_SWAP (SDK sys/stdio.h)
        exchanged = True
    else:
        rename_bundle(staged, installed, 0x00000004)  # RENAME_EXCL: never overwrite a new arrival
        new_install = True
    try:
        verify_bundle(installed)
        if exchanged:
            call("/usr/bin/ditto", staged, recovery / "ARMSX2.app")
            # Compare content before retiring the original old bundle from staging.
            call("/usr/bin/diff", "-qr", staged, recovery / "ARMSX2.app")
        print("Installed " + str(installed))
        if exchanged:
            print("Previous bundle preserved at " + str(recovery / "ARMSX2.app"))
        preserve_stage = False
    except BaseException:
        # Preserve the original atomically if post-install validation or backup fails.
        try:
            if exchanged:
                rename_bundle(staged, installed, 0x00000002)
                exchanged = False
            elif new_install:
                rename_bundle(installed, staged, 0x00000004)
                new_install = False
            preserve_stage = False
        except BaseException as rollback_error:
            preserve_stage = True
            print("Rollback failed; preserve and inspect " + str(stage_dir) + ": " + str(rollback_error), file=sys.stderr)
        raise
except BaseException as error:
    print("Install failed: " + str(error), file=sys.stderr)
    if preserve_stage:
        print("Recovery staging retained at " + str(stage_dir), file=sys.stderr)
    sys.exit(1)
finally:
    if stage_dir is not None and not preserve_stage:
        shutil.rmtree(stage_dir)
    lock.rmdir()
PY
}

# Serialize all cooperative operations before configuration/build or launch.
# This lives in ignored build output, so build/run need no /Applications rights.
case "${1:-}" in build|install|run) ;; *) die "Usage: $0 {build|install|run [game.iso]}" ;; esac
mkdir -p "$BUILD"
OPERATION_LOCK="$BUILD/.macos-dev-operation.lock"
mkdir "$OPERATION_LOCK" 2>/dev/null ||
	die "Another helper operation is active, or an interrupted run left $OPERATION_LOCK; inspect it before retrying."
trap 'rmdir "$OPERATION_LOCK" || echo "macos-dev: operation lock retained at $OPERATION_LOCK" >&2' EXIT

case "$1" in
	build)
		[ "$#" -eq 1 ] || die "Usage: $0 build"
		build_app ;;
	install)
		[ "$#" -eq 1 ] || die "Usage: $0 install"
		install_app ;;
	run)
		[ "$#" -le 2 ] || die "Usage: $0 run [game.iso]"
		[ -d "$APP" ] || die "Install the app first."
		if [ "$#" -eq 2 ]; then
			check_stopped
			[ -f "$2" ] || die "Game file not found: $2"
			game="$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")"
			/usr/bin/open "$APP" --args "$game"
		else
			/usr/bin/open "$APP"
		fi
		# Keep the operation lock until the launch is observable, preventing an
		# install immediately after open returns but before the process starts.
		observed=0
		for attempt in {1..100}; do
			status=0
			/usr/bin/pgrep -x ARMSX2 >/dev/null || status=$?
			if [ "$status" -eq 0 ]; then observed=1; break; fi
			[ "$status" -eq 1 ] || die "Could not check the launched app."
			sleep 0.1
		done
		[ "$observed" -eq 1 ] || die "App launch was not observable within 10 seconds."
		;;
	*) die "Usage: $0 {build|install|run [game.iso]}" ;;
esac
