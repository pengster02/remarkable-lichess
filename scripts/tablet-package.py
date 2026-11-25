import fcntl
import os
from pathlib import Path
import shutil
import sys


def require_bundle(directory):
    for filename in ("backend/entry", "manifest.json", "resources.rcc"):
        path = directory / filename
        if not path.is_file() or not path.stat().st_size:
            raise ValueError(f"The app bundle is incomplete. Missing or empty file: {filename}")
    if not os.access(directory / "backend/entry", os.X_OK):
        raise ValueError("The app bundle is incomplete. The backend entry is not executable.")


def discard_previous(path):
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)


def restore_previous(bundle, previous):
    if os.path.lexists(previous) and not os.path.lexists(bundle):
        previous.rename(bundle)


def publish(bundle, previous, stage):
    require_bundle(stage)
    # Match a normal mkdir once the private build directory is ready to publish.
    mask = os.umask(0)
    os.umask(mask)
    stage.chmod(0o777 & ~mask)
    # Keep the prior directory recoverable during the swap. File-by-file
    # replacement can mix builds, and symlink generations need reader-aware cleanup.
    discard_previous(previous)
    if os.path.lexists(bundle):
        bundle.rename(previous)
    try:
        stage.rename(bundle)
    except OSError:
        restore_previous(bundle, previous)
        raise
    try:
        discard_previous(previous)
    except OSError as error:
        print(f"Published the app bundle. Could not remove {previous}: {error}", file=sys.stderr)


def main(mode, path):
    dist = Path(__file__).resolve().parent.parent / "dist"
    bundle = dist / "remarkable-lichess"
    previous = dist / ".remarkable-lichess.previous"
    if not dist.is_dir():
        raise ValueError("The app bundle is incomplete. Run scripts/build-rm.sh first.")

    # A directory lock works from a read-only checkout. A lock file requires a
    # write, and a mkdir lock can linger after a crash.
    lock = os.open(dist, os.O_RDONLY | os.O_DIRECTORY)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        restore_previous(bundle, previous)
        if mode == "publish":
            publish(bundle, previous, path)
        elif mode == "snapshot":
            require_bundle(bundle)
            shutil.copytree(bundle, path)
        else:
            raise ValueError(f"Unknown tablet package operation: {mode}")
    finally:
        os.close(lock)


if __name__ == "__main__":
    mode, directory = sys.argv[1:]
    try:
        main(mode, Path(directory))
    except (OSError, ValueError) as error:
        sys.exit(str(error))
