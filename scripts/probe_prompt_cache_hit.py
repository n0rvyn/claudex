#!/usr/bin/env python3
"""
Probe whether /responses exposes prompt-cache-hit metrics in response.usage.

Sends 3 consecutive /responses requests with identical prompt_cache_key,
instructions, and input[0] to trigger an upstream cache hit on requests 2 and 3.
Parses the final response.completed SSE event from each request and prints
the full response.usage object so we can detect any cache-specific subfields
(e.g. prompt_cache_hit_tokens, input_tokens_details.cached_tokens, etc.).

Usage:
    # Dry run (prints plan without HTTP calls):
    python3 scripts/probe_prompt_cache_hit.py --dry-run

    # Real probe (requires ~/.codex/auth.json):
    python3 scripts/probe_prompt_cache_hit.py > /tmp/cache-hit-probe.jsonl
"""
from __future__ import annotations

import argparse
import json
import ssl
import sys
import urllib.error
import urllib.request
from pathlib import Path

import zstandard as zstd

UPSTREAM_URL = "https://chatgpt.com/backend-api/codex/responses"
PROMPT_CACHE_KEY = "modelbridge-probe-2026-04-23"


def load_auth() -> tuple[str, str]:
    """Load and validate credentials from ~/.codex/auth.json."""
    p = Path("~/.codex/auth.json").expanduser()
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


def parse_sse_events(body: bytes) -> list[dict]:
    """Parse SSE text into a list of JSON event dicts."""
    text = body.decode("utf-8", errors="replace")
    events: list[dict] = []
    for chunk in text.split("\n\n"):
        for line in chunk.splitlines():
            if not line.startswith("data: "):
                continue
            payload = line[6:]
            if payload == "[DONE]":
                continue
            try:
                events.append(json.loads(payload))
            except json.JSONDecodeError:
                continue
    return events


def extract_response_completed(events: list[dict]) -> dict | None:
    """Return the response.completed event's `response` sub-object, or None."""
    for event in events:
        if event.get("type") == "response.completed":
            return event.get("response")
    return None


def post_responses(
    payload: dict, access_token: str, account_id: str
) -> tuple[int, list[dict]]:
    """
    POST a JSON payload (zstd-compressed) to UPSTREAM_URL.
    Returns (http_status, parsed_sse_events).
    """
    raw = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    body_bytes = zstd.ZstdCompressor().compress(raw)

    req = urllib.request.Request(UPSTREAM_URL, data=body_bytes, method="POST")
    req.add_header("Authorization", f"Bearer {access_token}")
    req.add_header("chatgpt-account-id", account_id)
    req.add_header("accept", "text/event-stream")
    req.add_header("content-type", "application/json")
    req.add_header("content-encoding", "zstd")
    req.add_header("user-agent", "modelbridge-probe/prompt-cache-hit")

    try:
        with urllib.request.urlopen(req, context=ssl.create_default_context(), timeout=60) as r:
            raw_body = r.read()
            return r.status, parse_sse_events(raw_body)
    except urllib.error.HTTPError as e:
        raw_body = e.read()
        return e.code, parse_sse_events(raw_body)
    except Exception as e:
        return 0, []


def build_request(n: int) -> dict:
    """Build request payload for probe request n (1-indexed)."""
    return {
        "model": "gpt-5.4",
        "instructions": "You are a helpful assistant.",
        "input": [
            {
                "type": "message",
                "role": "user",
                "content": [
                    {
                        "type": "input_text",
                        "text": (
                            "What is the capital of France? Reply with just the city name."
                        ),
                    }
                ],
            }
        ],
        "tools": [],
        "tool_choice": "none",
        "parallel_tool_calls": False,
        "reasoning": {"effort": "medium"},
        "store": False,
        "stream": True,
        "include": ["reasoning.encrypted_content"],
        "service_tier": "priority",
        "prompt_cache_key": PROMPT_CACHE_KEY,
        "text": {"verbosity": "low"},
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Probe whether /responses surfaces prompt-cache-hit metrics. "
            "Sends 3 identical requests with the same prompt_cache_key."
        )
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help=(
            "Print the probe plan and exit without making HTTP calls."
        ),
    )
    args = parser.parse_args()

    if args.dry_run:
        print(
            f"dry-run: 3 requests to {UPSTREAM_URL} with prompt_cache_key={PROMPT_CACHE_KEY}",
            file=sys.stderr,
        )
        print(
            json.dumps(
                {
                    "dry_run": True,
                    "url": UPSTREAM_URL,
                    "cache_key": PROMPT_CACHE_KEY,
                    "requests": [
                        {
                            "n": 1,
                            "description": "cold request — establishes upstream cache entry",
                        },
                        {
                            "n": 2,
                            "description": "cache hit expected — same prompt_cache_key",
                        },
                        {
                            "n": 3,
                            "description": "cache hit expected — same prompt_cache_key",
                        },
                    ],
                    "parse": "response.completed.response.usage from each SSE stream",
                },
                ensure_ascii=False,
            )
        )
        return 0

    access_token, account_id = load_auth()

    results: list[dict] = []
    for n in [1, 2, 3]:
        payload = build_request(n)
        status, events = post_responses(payload, access_token, account_id)
        response_obj = extract_response_completed(events)
        usage = response_obj.get("usage") if response_obj else None

        record = {
            "request_n": n,
            "http_status": status,
            "usage": usage,
            # Surface the entire response object for field discovery
            "response": response_obj,
        }
        results.append(record)
        print(json.dumps(record, ensure_ascii=False))

    # Print a summary line for easy grep
    print(
        json.dumps(
            {
                "type": "summary",
                "candidates": [
                    "prompt_cache_hit_tokens",
                    "input_tokens_details.cached_tokens",
                    "input_tokens_details.prompt_cache_hit",
                    "cached_tokens",
                ],
                "all_usage_keys": list(
                    set(
                        k
                        for r in results
                        if r.get("usage")
                        for k in r["usage"].keys()
                    )
                ),
            },
            ensure_ascii=False,
        ),
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
