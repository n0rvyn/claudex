#!/usr/bin/env python3
"""
Probe reasoning.effort values against the real Codex ChatGPT endpoint.

Reads ~/.codex/auth.json for credentials, POSTs a minimal /responses request
for each reasoning effort candidate, records HTTP status + first-line error body (if any)
to stdout as one JSON record per candidate.

Usage:
    python3 scripts/probe_reasoning_effort.py \
        --efforts low medium high xhigh \
        --out docs/research/2026-04-22-reasoning-effort-probe.md
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from _probe_common import base_payload, load_auth, post_probe, write_table

DEFAULT_EFFORTS = ["low", "medium", "high", "xhigh"]


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Probe reasoning.effort values against https://chatgpt.com/backend-api/codex/responses"
    )
    ap.add_argument(
        "--efforts",
        nargs="+",
        default=DEFAULT_EFFORTS,
        help=f"Reasoning effort values to probe (default: {' '.join(DEFAULT_EFFORTS)})",
    )
    ap.add_argument(
        "--out",
        help="Path to write markdown results table (e.g. docs/research/2026-04-22-reasoning-effort-probe.md)",
    )
    args = ap.parse_args()

    access_token, account_id = load_auth()

    results = []
    for effort in args.efforts:
        payload = base_payload()
        payload["reasoning"] = {"effort": effort}
        probe_result = post_probe(payload, access_token, account_id)
        probe_result["effort"] = effort
        results.append(probe_result)

    out_path = Path(args.out) if args.out else None
    write_table(results, param_key="effort", param_label="reasoning.effort", out_path=out_path)


if __name__ == "__main__":
    raise SystemExit(main())
