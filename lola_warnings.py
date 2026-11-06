#!/usr/bin/env python3
"""Print the validation warnings Lola finds in an installed module, one per line.

`lola mod add` prints these once; `lola mod update`, `lola install` and `lola update` print nothing,
so an invalid entry (for example an unsupported MCP type) would be dropped without a trace.
Uses Lola's own loader, so it stays in step with the pinned Lola commit.
"""
import sys

from lola.config import MODULES_DIR
from lola.models import Module


def main(name):
    module = Module.from_path(MODULES_DIR / name, None)
    if module is None:
        print("module %s could not be loaded" % name)
        return 0
    for warning in module.format_warnings:
        print(warning)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
