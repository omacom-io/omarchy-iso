"""Orchestrator progress lines.

These land in the install log, not on a screen: omarchy-install-dashboard owns
the visible UI, captures the orchestrator's stdout into the support log, and
strips CSI sequences on the way in. The colouring was therefore never seen by
anyone, while gum charged a Go process start per line for it. Plain writes keep
the same indented shape at no cost.

Flush every line: pacstrap and arch-chroot inherit this fd, so buffering here
would reorder our lines against theirs in the log.
"""

from __future__ import annotations

import sys


def _emit(text: str) -> None:
    sys.stdout.write(f"\n    {text}\n")
    sys.stdout.flush()


def info(text: str) -> None:
    _emit(text)


def error(text: str) -> None:
    _emit(text)
