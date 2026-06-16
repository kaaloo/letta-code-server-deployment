#!/usr/bin/env python3
"""PostToolUse hook: push memfs commits to the Letta server after memory edits.

Reads hook input from stdin. The memory tool auto-commits to
~/.letta/agents/<agent-id>/memory on each call. We push the result so the
desktop Memory UI stays in sync.

Failure modes:
  - Agent id missing: skip silently (not a memfs session).
  - Repo not a git repo: skip silently (memfs not enabled).
  - Nothing to push: git push exits 0 with "Everything up-to-date".
  - Push fails (network, auth): write to a log and continue — do not block
    the agent's tool result.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

LOG = Path.home() / ".letta" / "memfs-autopush.log"


def _log(msg: str) -> None:
    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        with LOG.open("a") as f:
            f.write(msg.rstrip() + "\n")
    except Exception:
        pass


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except Exception as e:
        _log(f"[{_ts()}] autopush: bad stdin: {e}")
        return 0  # never block

    agent_id = (
        data.get("agent_id")
        or data.get("AGENT_ID")
        or os.environ.get("LETTA_AGENT_ID")
        or os.environ.get("AGENT_ID")
    )
    if not agent_id:
        return 0

    repo = Path.home() / ".letta" / "agents" / agent_id / "memory"
    if not (repo / ".git").exists():
        return 0  # memfs not enabled for this agent

    try:
        result = subprocess.run(
            ["git", "push", "origin", "main"],
            cwd=str(repo),
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
    except subprocess.TimeoutExpired:
        _log(f"[{_ts()}] autopush: push timed out for {agent_id}")
        return 0
    except Exception as e:
        _log(f"[{_ts()}] autopush: subprocess error: {e}")
        return 0

    if result.returncode == 0:
        if "Everything up-to-date" not in result.stdout and result.stdout.strip():
            _log(f"[{_ts()}] autopush: {agent_id}: {result.stdout.strip()}")
    else:
        _log(
            f"[{_ts()}] autopush: push failed for {agent_id} "
            f"(rc={result.returncode}): {result.stderr.strip() or result.stdout.strip()}"
        )
    return 0


def _ts() -> str:
    import datetime
    return datetime.datetime.now().isoformat(timespec="seconds")


if __name__ == "__main__":
    sys.exit(main())
