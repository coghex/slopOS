#!/usr/bin/env python3
from __future__ import annotations
import os
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parent.parent
SSH_GUEST = ROOT_DIR / "scripts" / "ssh-guest.sh"
SCP_TO_GUEST = ROOT_DIR / "scripts" / "scp-to-guest.sh"
GUEST_TOOL = os.environ.get(
    "SLOPOS_GUEST_TOOL",
    os.environ.get(
        "SLOPOS_GUEST_LINKER",
        "/Volumes/slopos-data/toolchain/selfhost-sysroot/final/bin/selfhost-gcc",
    ),
)
DEFAULT_GUEST_TOOL = os.environ.get(
    "SLOPOS_GUEST_LINKER",
    "/Volumes/slopos-data/toolchain/selfhost-sysroot/final/bin/selfhost-gcc",
)
GUEST_STAGE_BASE = os.environ.get("SLOPOS_GUEST_LINK_STAGE_BASE", "/tmp/sloppkg-link")
KEEP_STAGE = os.environ.get("SLOPOS_GUEST_LINK_KEEP_STAGE") == "1"

PATH_VALUE_FLAGS = {
    "-I": "dir",
    "-L": "dir",
    "-MF": "out",
    "-MQ": "plain",
    "-MT": "plain",
    "-include": "file",
    "-imacros": "file",
    "-iquote": "dir",
    "-isystem": "dir",
    "-o": "out",
    "--sysroot": "dir",
}
PATH_PREFIX_FLAGS = {
    "-I": "dir",
    "-L": "dir",
    "-MF": "out",
}
PATH_EQUALS_FLAGS = {
    "--sysroot": "dir",
}


def run_local(args: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(args, check=True, text=False, **kwargs)


def run_guest(command: str, **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run([str(SSH_GUEST), command], check=True, text=False, **kwargs)


def host_path_for(argument: str) -> Path | None:
    candidate = Path(argument)
    if candidate.exists():
        return candidate.resolve()
    return None


def guest_mirror_path(stage_root: str, host_path: Path) -> str:
    return f"{stage_root}/hostfs{host_path.as_posix()}"


def ensure_guest_dir(path: str) -> None:
    run_guest(f"mkdir -p {shlex.quote(path)}")


def copy_file_to_guest(stage_root: str, host_path: Path) -> str:
    guest_path = guest_mirror_path(stage_root, host_path)
    ensure_guest_dir(str(Path(guest_path).parent))
    run_local([str(SCP_TO_GUEST), str(host_path), guest_path])
    return guest_path


def copy_dir_to_guest(stage_root: str, host_path: Path) -> str:
    guest_path = guest_mirror_path(stage_root, host_path)
    ensure_guest_dir(str(Path(guest_path).parent))
    run_local([str(SCP_TO_GUEST), str(host_path), f"{Path(guest_path).parent.as_posix()}/"])
    return guest_path


def guest_output_path(stage_root: str, host_path: Path) -> str:
    return f"{stage_root}/outfs{host_path.as_posix()}"


def rewrite_args(stage_root: str, argv: list[str]) -> tuple[list[str], dict[Path, str]]:
    rewritten: list[str] = []
    outputs: dict[Path, str] = {}
    expect_flag: str | None = None

    for arg in argv:
        if expect_flag is not None:
            kind = PATH_VALUE_FLAGS[expect_flag]
            if kind == "plain":
                rewritten.append(arg)
            else:
                if kind == "dir":
                    host_path = host_path_for(arg)
                    rewritten.append(copy_dir_to_guest(stage_root, host_path) if host_path else arg)
                elif kind == "file":
                    host_path = host_path_for(arg)
                    rewritten.append(copy_file_to_guest(stage_root, host_path) if host_path else arg)
                else:
                    host_path = Path(arg).resolve()
                    guest_output = guest_output_path(stage_root, host_path)
                    ensure_guest_dir(str(Path(guest_output).parent))
                    outputs[host_path] = guest_output
                    rewritten.append(guest_output)
            expect_flag = None
            continue

        if arg in PATH_VALUE_FLAGS:
            rewritten.append(arg)
            expect_flag = arg
            continue

        if arg.startswith("@"):
            response_path = host_path_for(arg[1:])
            rewritten.append(f"@{copy_file_to_guest(stage_root, response_path)}" if response_path else arg)
            continue

        matched_prefix = False
        for prefix, kind in PATH_PREFIX_FLAGS.items():
            if arg.startswith(prefix) and len(arg) > len(prefix):
                host_path = host_path_for(arg[len(prefix) :])
                if kind == "dir" and host_path:
                    rewritten.append(f"{prefix}{copy_dir_to_guest(stage_root, host_path)}")
                elif kind == "out":
                    resolved_output = Path(arg[len(prefix) :]).resolve()
                    guest_output = guest_output_path(stage_root, resolved_output)
                    ensure_guest_dir(str(Path(guest_output).parent))
                    outputs[resolved_output] = guest_output
                    rewritten.append(f"{prefix}{guest_output}")
                else:
                    rewritten.append(arg)
                matched_prefix = True
                break
        if matched_prefix:
            continue

        matched_equals = False
        for prefix, kind in PATH_EQUALS_FLAGS.items():
            needle = f"{prefix}="
            if arg.startswith(needle):
                host_path = host_path_for(arg[len(needle) :])
                if kind == "dir" and host_path:
                    rewritten.append(f"{needle}{copy_dir_to_guest(stage_root, host_path)}")
                else:
                    rewritten.append(arg)
                matched_equals = True
                break
        if matched_equals:
            continue

        host_path = host_path_for(arg)
        if host_path:
            if host_path.is_dir():
                rewritten.append(copy_dir_to_guest(stage_root, host_path))
            else:
                rewritten.append(copy_file_to_guest(stage_root, host_path))
            continue

        rewritten.append(arg)

    if expect_flag is not None:
        raise SystemExit("guest-linker: unterminated path flag while rewriting arguments")

    return rewritten, outputs


def main() -> int:
    if not SSH_GUEST.exists() or not SCP_TO_GUEST.exists():
        raise SystemExit("guest-linker: guest transport scripts are missing")

    stage_root = f"{GUEST_STAGE_BASE.rstrip('/')}/{uuid.uuid4().hex}"
    ensure_guest_dir(f"{stage_root}/hostfs")
    ensure_guest_dir(f"{stage_root}/out")

    succeeded = False

    try:
        rewritten_args, outputs = rewrite_args(stage_root, sys.argv[1:])
        with tempfile.NamedTemporaryFile("w", delete=False) as response_file:
            for arg in rewritten_args:
                response_file.write(arg)
                response_file.write("\n")
            local_response_path = Path(response_file.name)

        guest_response_path = f"{stage_root}/args.rsp"
        run_local([str(SCP_TO_GUEST), str(local_response_path), guest_response_path])
        guest_command = f"{shlex.quote(GUEST_TOOL)} @{shlex.quote(guest_response_path)}"
        run_guest(guest_command)

        for output_host_path, guest_output in outputs.items():
            output_host_path.parent.mkdir(parents=True, exist_ok=True)
            with output_host_path.open("wb") as output_file:
                run_guest(f"cat {shlex.quote(guest_output)}", stdout=output_file)

            mode = output_host_path.stat().st_mode
            output_host_path.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        succeeded = True
    except subprocess.CalledProcessError as exc:
        print(f"guest-linker: guest stage preserved at {stage_root}", file=sys.stderr)
        return exc.returncode
    finally:
        if "local_response_path" in locals():
            try:
                local_response_path.unlink()
            except FileNotFoundError:
                pass
        if succeeded and not KEEP_STAGE:
            try:
                run_guest(f"rm -rf {shlex.quote(stage_root)}")
            except subprocess.CalledProcessError:
                pass

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
