#!/usr/bin/env python3
"""Bundle standalone CLI runtime tools (sf-dl, 7zz, unar, optional innoextract) into Chrysa.app
and relocate all non-system Mach-O dylib dependencies into Contents/Frameworks/ so the app
runs cleanly on Macs without Homebrew installed."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys


def run_checked(cmd: list[str]) -> str:
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"Command failed ({proc.returncode}): {' '.join(cmd)}\n{proc.stderr.strip()}")
    return proc.stdout


def dylib_install_id(path: str) -> str | None:
    out = run_checked(["/usr/bin/otool", "-D", path])
    lines = [line.strip() for line in out.splitlines() if line.strip()]
    return lines[1] if len(lines) >= 2 else None


def linked_libraries(path: str) -> list[str]:
    out = run_checked(["/usr/bin/otool", "-L", path])
    own_id = dylib_install_id(path)
    deps: list[str] = []
    for raw in out.splitlines()[1:]:
        line = raw.strip()
        if not line:
            continue
        dep = line.split(" (", 1)[0].strip()
        if own_id and dep == own_id:
            continue
        deps.append(dep)
    return deps


def is_system_library(dep: str) -> bool:
    return dep.startswith("/usr/lib/") or dep.startswith("/System/")


def resolve_dependency_source(
    dep: str,
    owner_original_dir: str,
    asset_frameworks_dir: str,
) -> str | None:
    if dep.startswith("@executable_path/../Frameworks/"):
        name = dep.removeprefix("@executable_path/../Frameworks/")
        cand = os.path.join(asset_frameworks_dir, name)
        return os.path.realpath(cand) if os.path.exists(cand) else None

    if dep.startswith("@loader_path/"):
        name = dep.removeprefix("@loader_path/")
        for base in (owner_original_dir, asset_frameworks_dir):
            cand = os.path.join(base, name)
            if os.path.exists(cand):
                return os.path.realpath(cand)
        return None

    if dep.startswith("/"):
        return os.path.realpath(dep) if os.path.exists(dep) else None

    return None


def copy_executable(src: str, dest: str) -> None:
    real_src = os.path.realpath(src)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    shutil.copyfile(real_src, dest)
    os.chmod(dest, 0o755)


def pick_first_executable(candidates: list[str]) -> str | None:
    for path in candidates:
        if path and os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None


def main() -> int:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <staging_bundle_app> <asset_app>", file=sys.stderr)
        return 2

    bundle_app = os.path.abspath(sys.argv[1])
    asset_app = os.path.abspath(sys.argv[2])

    macos_dir = os.path.join(bundle_app, "Contents", "MacOS")
    frameworks_dir = os.path.join(bundle_app, "Contents", "Frameworks")
    asset_macos_dir = os.path.join(asset_app, "Contents", "MacOS")
    asset_frameworks_dir = os.path.join(asset_app, "Contents", "Frameworks")

    os.makedirs(macos_dir, exist_ok=True)

    tool_specs: list[tuple[str, list[str], bool]] = [
        (
            "sf-dl",
            [
                os.path.join(asset_macos_dir, "sf-dl"),
                "/opt/homebrew/bin/aria2c",
                "/usr/local/bin/aria2c",
            ],
            False,
        ),
        (
            "7zz",
            [
                os.path.join(asset_macos_dir, "7zz"),
                "/opt/homebrew/bin/7zz",
                "/usr/local/bin/7zz",
            ],
            False,
        ),
        (
            "unar",
            [
                os.path.join(asset_macos_dir, "unar"),
                "/opt/homebrew/bin/unar",
                "/usr/local/bin/unar",
            ],
            False,
        ),
    ]

    if os.environ.get("CHRYSA_BUNDLE_INNOEXTRACT") == "1" or os.path.isfile(
        os.path.join(asset_macos_dir, "innoextract")
    ):
        tool_specs.append(
            (
                "innoextract",
                [
                    os.path.join(asset_macos_dir, "innoextract"),
                    "/opt/homebrew/bin/innoextract",
                    "/usr/local/bin/innoextract",
                ],
                False,
            )
        )

    staged_tools: list[tuple[str, str, str]] = []  # (name, dest_path, original_dir)
    for name, candidates, required in tool_specs:
        src = pick_first_executable(candidates)
        if not src:
            if required:
                raise RuntimeError(f"Required runtime tool not found: {name}")
            continue
        dest = os.path.join(macos_dir, name)
        copy_executable(src, dest)
        staged_tools.append((name, dest, os.path.dirname(os.path.realpath(src))))

    # Queue of (bundled_path, original_source_dir, is_dylib)
    work_queue: list[tuple[str, str, bool]] = [
        (dest, orig_dir, False) for _, dest, orig_dir in staged_tools
    ]
    bundled_dylibs: dict[str, str] = {}  # basename -> bundled_path
    processed: set[str] = set()

    while work_queue:
        target_path, owner_orig_dir, is_dylib = work_queue.pop(0)
        if target_path in processed:
            continue
        processed.add(target_path)

        deps = linked_libraries(target_path)
        install_tool_changes: list[tuple[str, str]] = []

        for dep in deps:
            if is_system_library(dep):
                continue

            dep_basename = os.path.basename(dep)
            new_ref = (
                f"@loader_path/{dep_basename}"
                if is_dylib
                else f"@executable_path/../Frameworks/{dep_basename}"
            )

            if dep_basename not in bundled_dylibs:
                resolved_src = resolve_dependency_source(
                    dep=dep,
                    owner_original_dir=owner_orig_dir,
                    asset_frameworks_dir=asset_frameworks_dir,
                )
                if not resolved_src:
                    raise RuntimeError(
                        f"Cannot locate non-system dylib '{dep}' required by {os.path.basename(target_path)}"
                    )
                os.makedirs(frameworks_dir, exist_ok=True)
                dylib_dest = os.path.join(frameworks_dir, dep_basename)
                copy_executable(resolved_src, dylib_dest)
                bundled_dylibs[dep_basename] = dylib_dest
                work_queue.append((dylib_dest, os.path.dirname(resolved_src), True))

            if dep != new_ref:
                install_tool_changes.append((dep, new_ref))

        cmd = ["/usr/bin/install_name_tool"]
        if is_dylib:
            desired_id = f"@loader_path/{os.path.basename(target_path)}"
            if dylib_install_id(target_path) != desired_id:
                cmd += ["-id", desired_id]
        for old_ref, new_ref in install_tool_changes:
            cmd += ["-change", old_ref, new_ref]
        if len(cmd) > 1:
            cmd.append(target_path)
            run_checked(cmd)

    # Strict verification: guarantee zero external Homebrew / /usr/local dylib leaks
    verify_targets: list[tuple[str, bool]] = [(dest, False) for _, dest, _ in staged_tools]
    verify_targets += [(path, True) for path in sorted(bundled_dylibs.values())]

    for path, is_dylib in verify_targets:
        for dep in linked_libraries(path):
            if is_system_library(dep):
                continue
            expected_prefix = "@loader_path/" if is_dylib else "@executable_path/../Frameworks/"
            if not dep.startswith(expected_prefix):
                raise RuntimeError(
                    f"Unrelocated external dependency in {os.path.basename(path)}: {dep}"
                )
            ref_name = dep.removeprefix(expected_prefix)
            if not os.path.isfile(os.path.join(frameworks_dir, ref_name)):
                raise RuntimeError(
                    f"Missing bundled dylib '{ref_name}' referenced by {os.path.basename(path)}"
                )

    tool_names = ", ".join(name for name, _, _ in staged_tools) or "none"
    print(f"Bundled runtime tools: {tool_names} ({len(bundled_dylibs)} relocated dylibs)")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"bundle-runtime-tools error: {exc}", file=sys.stderr)
        raise SystemExit(1)
