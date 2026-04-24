#!/usr/bin/env python3
"""
Shared helpers for ModelBridge Phase 2 probe scripts.

Provides load_auth(), redact(), and the base minimal_payload() used by
all three probe scripts (models, reasoning effort, text verbosity).
"""
from __future__ import annotations

import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

import zstandard as zstd

UPSTREAM_URL = "https://chatgpt.com/backend-api/codex/responses"


def load_auth() -> tuple[str, str]:
    """Load and validate credentials from ~/.codex/auth.json."""
    p = Path(os.path.expanduser("~/.codex/auth.json"))
    if not p.exists():
        print(
            json.dumps({"error": f"auth file not found at {p}. Run `codex login` first."}),
            file=sys.stderr,
        )
        sys.exit(2)
    data = json.loads(p.read_text("utf-8"))
    t = data.get("tokens") or {}
    if not t.get("access_token") or not t.get("account_id"):
        print(
            json.dumps(
                {
                    "error": (
                        f"auth file at {p} missing tokens.access_token or tokens.account_id"
                    )
                }
            ),
            file=sys.stderr,
        )
        sys.exit(2)
    return t["access_token"], t["account_id"]


def redact(text: str) -> str:
    """Strip potential auth strings from upstream error bodies before writing to disk."""
    text = re.sub(r"(?i)(bearer\s+)[A-Za-z0-9._-]+", r"\1<REDACTED>", text)
    text = re.sub(r'(?i)(access_token"\s*:\s*")[^"]+', r"\1<REDACTED>", text)
    text = re.sub(r'(?i)(account_id"\s*:\s*")[^"]+', r"\1<REDACTED>", text)
    return text


def base_payload() -> dict[str, Any]:
    """Return the minimal /responses payload with no model/effort/verbosity overrides."""
    return {
        "model": "gpt-5.4",
        "instructions": "",
        "input": [
            {
                "type": "message",
                "role": "user",
                "content": [{"type": "input_text", "text": "Reply OK."}],
            }
        ],
        "tools": [],
        "tool_choice": "auto",
        "parallel_tool_calls": False,
        "reasoning": {"effort": "xhigh"},
        "store": False,
        "stream": True,
        "include": ["reasoning.encrypted_content"],
        "service_tier": "priority",
        "prompt_cache_key": "probe-param",
        "text": {"verbosity": "low"},
    }


def post_probe(
    payload: dict[str, Any], access_token: str, account_id: str
) -> dict[str, Any]:
    """
    POST a JSON payload (zstd-compressed) to UPSTREAM_URL.
    Returns a dict with model/status/body_snippet/error.
    Per-request failures are captured and returned, never raised.
    """
    raw = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    body = zstd.ZstdCompressor().compress(raw)
    req = urllib.request.Request(UPSTREAM_URL, data=body, method="POST")
    req.add_header("Authorization", f"Bearer {access_token}")
    req.add_header("chatgpt-account-id", account_id)
    req.add_header("accept", "text/event-stream")
    req.add_header("content-type", "application/json")
    req.add_header("content-encoding", "zstd")
    req.add_header("user-agent", "modelbridge-probe/phase2")
    try:
        with urllib.request.urlopen(req, context=ssl.create_default_context(), timeout=30) as r:
            raw_body = r.read()
            return {
                "status": r.status,
                "body_snippet": redact(raw_body[:500].decode("utf-8", errors="replace")),
            }
    except urllib.error.HTTPError as e:
        return {
            "status": e.code,
            "body_snippet": redact(e.read().decode("utf-8", errors="replace")[:500]),
        }
    except Exception as e:
        # Never raise — per-request failures independently captured so other candidates still probe.
        return {"status": None, "error": redact(str(e))}


def write_table(
    results: list[dict[str, Any]],
    param_key: str,
    param_label: str,
    out_path: Path | None = None,
) -> None:
    """
    Write a markdown table of probe results to stdout (one JSON record per result)
    and optionally to a markdown file at out_path.
    """
    for r in results:
        print(json.dumps(r, ensure_ascii=False))
    if out_path:
        rows = []
        for r in results:
            snippet = r.get("body_snippet") or r.get("error") or ""
            # Escape pipe characters for markdown table
            snippet_escaped = snippet.replace("|", "\\|")
            rows.append(
                f"| `{r.get(param_key, '?')}` | {r.get('status')} | `{snippet_escaped}` |"
            )
        header = (
            f"# {param_label} Probe Report — 2026-04-22\n\n"
            f"| {param_label} | status | first-500-chars body |\n"
            "|---|---|---|\n"
        )
        out_path.write_text(header + "\n".join(rows) + "\n", encoding="utf-8")
