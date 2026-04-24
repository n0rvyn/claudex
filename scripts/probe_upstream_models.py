#!/usr/bin/env python3
"""
Probe upstream model IDs against the real Codex ChatGPT endpoint.

Reads ~/.codex/auth.json for credentials, POSTs a minimal /responses request
for each candidate model, records HTTP status + first-line error body (if any)
to stdout as one JSON record per candidate.

Usage:
    python3 scripts/probe_upstream_models.py \
        --models gpt-5.4 gpt-5.4-mini gpt-5.3-codex gpt-4.5 gpt-5.3-codex-spark \
        --out docs/research/2026-04-22-upstream-model-probe.md
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

# Add scripts/ to path so _probe_common can be imported
sys.path.insert(0, str(Path(__file__).parent))

from _probe_common import base_payload, load_auth, post_probe, redact, write_table


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Probe upstream model IDs against https://chatgpt.com/backend-api/codex/responses"
    )
    ap.add_argument(
        "--models",
        nargs="+",
        required=True,
        help="Model IDs to probe (e.g. gpt-5.4 gpt-5.4-mini gpt-5.3-codex gpt-4.5 gpt-5.3-codex-spark)",
    )
    ap.add_argument(
        "--out",
        help="Path to write markdown results table (e.g. docs/research/2026-04-22-upstream-model-probe.md)",
    )
    args = ap.parse_args()

    access_token, account_id = load_auth()

    results = []
    for model in args.models:
        payload = base_payload()
        payload["model"] = model
        probe_result = post_probe(payload, access_token, account_id)
        probe_result["model"] = model
        results.append(probe_result)

    out_path = Path(args.out) if args.out else None
    write_table(results, param_key="model", param_label="Upstream Model ID", out_path=out_path)


if __name__ == "__main__":
    raise SystemExit(main())
