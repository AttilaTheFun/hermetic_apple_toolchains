#!/usr/bin/env python3
"""Rewrites MODULE.bazel's machine-local registration block for CI.

GitHub's macOS runner images ship several Xcode versions under
/Applications; CI registers one of them as the hermetic Xcode by path,
exercising the same flow a consumer uses with a re-hosted copy.

Usage: register_ci_xcode.py /Applications/Xcode_26.5.app
"""

import pathlib
import re
import sys

BEGIN = "# --- BEGIN machine-local registration (rewritten by CI; keep markers) ---"
END = "# --- END machine-local registration ---"

xcode = sys.argv[1]
if not pathlib.Path(xcode, "Contents", "Developer").is_dir():
    sys.exit(f"error: {xcode} does not look like an Xcode.app")

block = f'''{BEGIN}
apple.xcode(
    name = "xcode26_5",
    aliases = ["xcode26"],
    default = True,
    path = "{xcode}",
)
{END}'''

module = pathlib.Path(__file__).parent.parent / "MODULE.bazel"
text = module.read_text()
new, count = re.subn(
    re.escape(BEGIN) + ".*?" + re.escape(END), block, text, flags=re.S
)
if count != 1:
    sys.exit("error: machine-local registration markers not found in MODULE.bazel")
module.write_text(new)
print(f"Registered {xcode} as hermetic Xcode 'xcode26_5'")
