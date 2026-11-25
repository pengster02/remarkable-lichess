import importlib.util
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest import mock


spec = importlib.util.spec_from_file_location(
    "tablet_package", Path(__file__).resolve().parent.parent / "tablet-package.py"
)
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


def make_bundle(path, version):
    (path / "backend").mkdir(parents=True)
    entry = path / "backend/entry"
    entry.write_text(version)
    entry.chmod(0o755)
    (path / "manifest.json").write_text(version)
    (path / "resources.rcc").write_text(version)


class TabletPackageTest(unittest.TestCase):
    def setUp(self):
        scratch = TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.bundle = self.root / "dist/remarkable-lichess"
        self.previous = self.bundle.with_name(".remarkable-lichess.previous")
        self.stage = self.bundle.with_name(".build")
        make_bundle(self.bundle, "original")
        patch = mock.patch.object(package, "__file__", self.root / "scripts/tablet-package.py")
        patch.start()
        self.addCleanup(patch.stop)

    def assert_version(self, bundle, version):
        package.require_bundle(bundle)
        for filename in ("backend/entry", "manifest.json", "resources.rcc"):
            self.assertEqual((bundle / filename).read_text(), version)

    def test_incomplete_build_keeps_previous_bundle(self):
        make_bundle(self.stage, "replacement")
        (self.stage / "resources.rcc").unlink()
        with self.assertRaisesRegex(ValueError, "resources.rcc"):
            package.main("publish", self.stage)
        self.assert_version(self.bundle, "original")

    def test_failed_publish_restores_the_previous_directory(self):
        make_bundle(self.stage, "replacement")
        rename = Path.rename

        def fail_publish(source, destination):
            if source == self.stage:
                raise OSError("injected publication failure")
            return rename(source, destination)

        with mock.patch.object(Path, "rename", fail_publish):
            with self.assertRaisesRegex(OSError, "injected publication failure"):
                package.main("publish", self.stage)
        self.assert_version(self.bundle, "original")
        self.assertFalse(self.previous.exists())

    def test_snapshot_recovers_an_interrupted_publication(self):
        self.bundle.rename(self.previous)
        snapshot = self.root / "snapshot"
        package.main("snapshot", snapshot)
        self.assert_version(snapshot, "original")
        self.assert_version(self.bundle, "original")
        self.assertFalse(self.previous.exists())

    def test_successful_rebuild_keeps_an_earlier_snapshot_intact(self):
        snapshot = self.root / "snapshot"
        package.main("snapshot", snapshot)
        make_bundle(self.stage, "replacement")
        package.main("publish", self.stage)
        self.assert_version(snapshot, "original")
        self.assert_version(self.bundle, "replacement")
        self.assertFalse(self.stage.exists())
        self.assertFalse(self.previous.exists())
