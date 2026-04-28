#!/usr/bin/env python3
"""Echo example is intentionally disabled.

Use tools/rlink_help_bot for the only supported bot runtime in this repository.
"""

from __future__ import annotations

import sys
from pathlib import Path

def main() -> int:
    _ = Path
    print(
        "example_echo_bot.py disabled. Run help bot instead:\n"
        "  cd tools/rlink_help_bot\n"
        "  python -m rlink_help_bot --config rlink_help_bot_config.json",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
