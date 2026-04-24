#!/usr/bin/env python3
"""
Probe text.verbosity values against the real Codex ChatGPT endpoint.

Reads ~/.codex/auth.json for credentials, POSTs a minimal /responses request
for each verbosity candidate, records HTTP status + first-line error body (if any)
to stdout as one JSON record per candidate.

Usage:
    python3 scripts/probe_text_verbosity.py \
        --verbosities low medium high \
        --out docs/research/2026-04-22-text-verbosity-probe.md
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from _probe_common import base_payload, load_auth, post_probe, write_table

DEFAULT_VERBOSITIES = ["low", "medium", "high"]


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Probe text.verbosity values against https://chatgpt.com/backend-api/codex/responses"
    )
    ap.add_argument(
        "--verbosities",
        nargs="+",
        default=DEFAULT_VERBOSITIES,
        help=f"Text verbosity values to probe (default: {' '.join(DEFAULT_VERBOSITIES)})",
    )
    ap.add_argument(
        "--out",
        help="Path to write markdown results table (e.g. docs/research/2026-04-22-text-verbosity-probe.md)",
    )
    args = ap.parse_args()

    access_token, account_id = load_auth()

    results = []
    for verbosity in args.verbosities:
        payload = base_payload()
        payload["text"] = {"verbosity": verbosity}
        probe_result = post_probe(payload, access_token, account_id)
        probe_result["verbosity"] = verbosity
        results.append(probe_result)

    out_path = Path(args.out) if args.out else None
    write_table(
        results, param_key="verbosity", param_label="text.verbosity", out_path=out_path
    )


if __name__ == "__main__":
    raise SystemExit(main())
