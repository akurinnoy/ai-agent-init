"""Unit tests for lola_warnings.py against a stand-in for Lola's loader.

Lola is installed only inside the image, so these tests inject minimal `lola.config` and `lola.models` modules.
They pin what this repo's code does: print one warning per line, print a clear line when the module cannot be
loaded, and always return 0 (a failure here must never block a workspace start). The real loader is exercised
by tests/run-tests.sh in Docker.

Run from the repo root:  python3 -m unittest discover -s tests/unit -v
"""
import contextlib
import importlib
import io
import sys
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

MODULES_DIR = Path("/modules")


def stand_in_lola(module):
    """Return (sys.modules entries, recorded from_path calls) for a Lola whose loader returns `module`."""
    calls = []

    class Module:
        @staticmethod
        def from_path(path, parent):
            calls.append((path, parent))
            return module

    config = types.ModuleType("lola.config")
    config.MODULES_DIR = MODULES_DIR
    models = types.ModuleType("lola.models")
    models.Module = Module
    package = types.ModuleType("lola")
    package.config = config
    package.models = models
    return {"lola": package, "lola.config": config, "lola.models": models}, calls


def run_main(module, name="my-module"):
    """Import lola_warnings against the stand-in Lola and run main(name): (rc, stdout, from_path calls)."""
    entries, calls = stand_in_lola(module)
    out = io.StringIO()
    with mock.patch.dict(sys.modules, entries):
        sys.modules.pop("lola_warnings", None)
        lola_warnings = importlib.import_module("lola_warnings")
        with contextlib.redirect_stdout(out):
            rc = lola_warnings.main(name)
    return rc, out.getvalue(), calls


class LolaWarningsTest(unittest.TestCase):
    def test_prints_each_warning_on_its_own_line(self):
        module = types.SimpleNamespace(format_warnings=["mcp.json: server 'x': unsupported type", "second"])
        rc, out, _ = run_main(module)
        self.assertEqual(rc, 0)
        self.assertEqual(out, "mcp.json: server 'x': unsupported type\nsecond\n")

    def test_prints_nothing_when_there_are_no_warnings(self):
        rc, out, _ = run_main(types.SimpleNamespace(format_warnings=[]))
        self.assertEqual(rc, 0)
        self.assertEqual(out, "")

    def test_reports_a_module_that_cannot_be_loaded_and_still_returns_zero(self):
        rc, out, _ = run_main(None, name="broken")
        self.assertEqual(rc, 0)
        self.assertEqual(out, "module broken could not be loaded\n")

    def test_loads_the_named_module_from_the_modules_directory(self):
        _, _, calls = run_main(types.SimpleNamespace(format_warnings=[]), name="my-module")
        self.assertEqual(calls, [(MODULES_DIR / "my-module", None)])


if __name__ == "__main__":
    unittest.main()
