#!/usr/bin/env python3
"""
Phase 5 V2 verification: count_tokens accuracy within 10% of upstream baseline.

For each of 5 payload shapes (single-turn text, multi-turn text, with system
prompt, with 16 tools, with tool_result) this script:

1. Sends an Anthropic-shape payload to the local daemon's
   POST /v1/messages/count_tokens endpoint -> daemon_bpe.
2. Sends a semantically equivalent /responses-shape payload directly to
   the real upstream endpoint (https://chatgpt.com/backend-api/codex/responses)
   -> parses the SSE stream for the response.completed event and reads
   response.usage.input_tokens -> upstream_baseline.
3. Computes deviation = |daemon_bpe - upstream_baseline| / upstream_baseline
   and prints a per-case row plus a summary (max deviation, ≤10% pass/fail).

Auth + zstd + SSE parsing reuses scripts/_probe_common.py helpers.
"""
from __future__ import annotations

import argparse
import io
import json
import os
import sys
import ssl
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

import zstandard as zstd

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _probe_common import UPSTREAM_URL, load_auth, base_payload


def parse_sse_events(body: bytes) -> list[dict]:
    text = body.decode("utf-8", errors="replace")
    events: list[dict] = []
    for chunk in text.split("\n\n"):
        for line in chunk.splitlines():
            if not line.startswith("data: "):
                continue
            data = line[6:]
            if data == "[DONE]":
                continue
            try:
                events.append(json.loads(data))
            except json.JSONDecodeError:
                continue
    return events


def upstream_input_tokens(payload: dict, access_token: str, account_id: str) -> tuple[int, str]:
    """POST payload to upstream, return (input_tokens, note). Empty note on success."""
    raw = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    body = zstd.ZstdCompressor().compress(raw)
    req = urllib.request.Request(UPSTREAM_URL, data=body, method="POST")
    req.add_header("Authorization", f"Bearer {access_token}")
    req.add_header("chatgpt-account-id", account_id)
    req.add_header("accept", "text/event-stream")
    req.add_header("content-type", "application/json")
    req.add_header("content-encoding", "zstd")
    req.add_header("user-agent", "claudex-phase5-v2/accuracy")
    ctx = ssl.create_default_context()
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=60) as resp:
            events = parse_sse_events(resp.read())
    except urllib.error.HTTPError as err:
        return -1, f"HTTP {err.code}: {err.read()[:200]!r}"
    except Exception as exc:
        return -1, f"error: {exc}"
    for event in events:
        if event.get("type") == "response.completed":
            usage = event.get("response", {}).get("usage") or {}
            if "input_tokens" in usage:
                return int(usage["input_tokens"]), ""
    return -1, "no response.completed with usage"


def daemon_count_tokens(anthropic_payload: dict, daemon_url: str, gateway_token: str) -> tuple[int, str]:
    url = daemon_url.rstrip("/") + "/v1/messages/count_tokens"
    body = json.dumps(anthropic_payload).encode("utf-8")
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("content-type", "application/json")
    req.add_header("x-api-key", gateway_token)
    req.add_header("anthropic-version", "2023-06-01")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read())
    except urllib.error.HTTPError as err:
        return -1, f"HTTP {err.code}: {err.read()[:200]!r}"
    except Exception as exc:
        return -1, f"error: {exc}"
    if "input_tokens" not in data:
        return -1, f"missing input_tokens in response: {data}"
    return int(data["input_tokens"]), ""


# ---- 5 payload cases ----

def _anth_text(text: str) -> list[dict]:
    return [{"type": "text", "text": text}]


def case1_single_turn_text() -> tuple[dict, dict]:
    text = "Say exactly SMOKEOK1."
    anth = {
        "model": "claude-haiku-4-5-20251001",
        "max_tokens": 32,
        "messages": [{"role": "user", "content": _anth_text(text)}],
    }
    resp = base_payload()
    resp["instructions"] = ""
    resp["input"] = [{"type": "message", "role": "user", "content": [{"type": "input_text", "text": text}]}]
    resp["tools"] = []
    return anth, resp


def case2_multi_turn_text() -> tuple[dict, dict]:
    anth = {
        "model": "claude-haiku-4-5-20251001",
        "max_tokens": 32,
        "messages": [
            {"role": "user", "content": _anth_text("What is 2+2? Answer with the digit only.")},
            {"role": "assistant", "content": _anth_text("4")},
            {"role": "user", "content": _anth_text("What is 10+10? Answer with the digit only.")},
        ],
    }
    resp = base_payload()
    resp["instructions"] = ""
    resp["input"] = [
        {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "What is 2+2? Answer with the digit only."}]},
        {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "4"}]},
        {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "What is 10+10? Answer with the digit only."}]},
    ]
    resp["tools"] = []
    return anth, resp


def case3_with_system() -> tuple[dict, dict]:
    system_text = "You are a terse math tutor. Respond in 3 words or fewer."
    user_text = "Three plus four."
    anth = {
        "model": "claude-haiku-4-5-20251001",
        "max_tokens": 32,
        "system": [{"type": "text", "text": system_text}],
        "messages": [{"role": "user", "content": _anth_text(user_text)}],
    }
    resp = base_payload()
    resp["instructions"] = system_text
    resp["input"] = [{"type": "message", "role": "user", "content": [{"type": "input_text", "text": user_text}]}]
    resp["tools"] = []
    return anth, resp


def _make_tool(name: str, desc: str) -> tuple[dict, dict]:
    input_schema = {
        "type": "object",
        "properties": {"path": {"type": "string"}, "limit": {"type": "integer"}},
        "required": ["path"],
        "additionalProperties": False,
    }
    anth_tool = {"name": name, "description": desc, "input_schema": input_schema}
    resp_tool = {
        "type": "function",
        "name": name,
        "description": desc,
        "parameters": input_schema,
        "strict": False,
    }
    return anth_tool, resp_tool


def case4_with_16_tools() -> tuple[dict, dict]:
    tool_specs = [
        ("ReadFile", "Read text content from a file path."),
        ("WriteFile", "Write text content to a file path."),
        ("ListDir", "List entries in a directory."),
        ("Grep", "Search for a regex pattern in files."),
        ("Glob", "Find files matching a glob pattern."),
        ("RunShell", "Execute a shell command and capture output."),
        ("FetchURL", "Fetch the HTTP response body for a URL."),
        ("Sleep", "Pause for a duration in milliseconds."),
        ("NowTime", "Return the current wall-clock time."),
        ("EnvGet", "Read an environment variable by name."),
        ("EnvSet", "Set an environment variable for this session."),
        ("FileStat", "Return metadata for a file path."),
        ("FileDelete", "Delete a file at a path."),
        ("Checksum", "Compute the SHA256 of a file."),
        ("Zip", "Create a zip archive from a directory."),
        ("Unzip", "Extract a zip archive into a directory."),
    ]
    anth_tools: list[dict] = []
    resp_tools: list[dict] = []
    for name, desc in tool_specs:
        a, r = _make_tool(name, desc)
        anth_tools.append(a)
        resp_tools.append(r)

    user_text = "Use any of the tools to read README.md."
    anth = {
        "model": "claude-haiku-4-5-20251001",
        "max_tokens": 64,
        "tools": anth_tools,
        "messages": [{"role": "user", "content": _anth_text(user_text)}],
    }
    resp = base_payload()
    resp["instructions"] = ""
    resp["input"] = [{"type": "message", "role": "user", "content": [{"type": "input_text", "text": user_text}]}]
    resp["tools"] = resp_tools
    return anth, resp


def case5_with_tool_result() -> tuple[dict, dict]:
    tool_name = "ReadFile"
    desc = "Read text content from a file path."
    a_tool, r_tool = _make_tool(tool_name, desc)

    user_text = "Please read notes.md and give a one-word summary."
    tool_call_id = "toolu_phase5_v2"
    tool_input = {"path": "notes.md"}
    tool_output = "The repository houses the ModelBridge gateway that bridges Anthropic requests to Codex subscription."

    anth = {
        "model": "claude-haiku-4-5-20251001",
        "max_tokens": 64,
        "tools": [a_tool],
        "messages": [
            {"role": "user", "content": _anth_text(user_text)},
            {"role": "assistant", "content": [
                {"type": "tool_use", "id": tool_call_id, "name": tool_name, "input": tool_input},
            ]},
            {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": tool_call_id, "content": [{"type": "text", "text": tool_output}]},
            ]},
        ],
    }

    resp = base_payload()
    resp["instructions"] = ""
    resp["input"] = [
        {"type": "message", "role": "user", "content": [{"type": "input_text", "text": user_text}]},
        {"type": "function_call", "call_id": tool_call_id, "name": tool_name, "arguments": json.dumps(tool_input, separators=(",", ":"))},
        {"type": "function_call_output", "call_id": tool_call_id, "output": tool_output},
    ]
    resp["tools"] = [r_tool]
    return anth, resp


# ---- main ----

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--daemon-url", default="http://127.0.0.1:4418")
    parser.add_argument("--gateway-token", default="phase5-v2-token")
    parser.add_argument("--report-path", default="docs/research/2026-04-24-count-tokens-accuracy-probe.md")
    args = parser.parse_args()

    access_token, account_id = load_auth()

    cases = [
        ("Case 1: single-turn text", case1_single_turn_text),
        ("Case 2: multi-turn text", case2_multi_turn_text),
        ("Case 3: with system prompt", case3_with_system),
        ("Case 4: with 16 tools", case4_with_16_tools),
        ("Case 5: with tool_result", case5_with_tool_result),
    ]

    rows: list[dict] = []
    for label, builder in cases:
        anth, resp = builder()
        daemon, d_err = daemon_count_tokens(anth, args.daemon_url, args.gateway_token)
        upstream, u_err = upstream_input_tokens(resp, access_token, account_id)
        if daemon < 0 or upstream < 0:
            rows.append({
                "label": label, "daemon": daemon, "upstream": upstream,
                "dev_pct": None, "daemon_err": d_err, "upstream_err": u_err,
            })
            continue
        deviation = abs(daemon - upstream) / upstream * 100.0 if upstream > 0 else float("inf")
        rows.append({"label": label, "daemon": daemon, "upstream": upstream, "dev_pct": deviation, "daemon_err": "", "upstream_err": ""})

    # Print summary
    max_dev = 0.0
    all_ok = True
    print(f"{'case':<32}  daemon  upstream   deviation")
    print("-" * 72)
    for row in rows:
        if row.get("dev_pct") is None:
            print(f"{row['label']:<32}  ---      ---         FAIL (daemon_err={row['daemon_err'] or '-'} upstream_err={row['upstream_err'] or '-'})")
            all_ok = False
            continue
        flag = "OK" if row["dev_pct"] <= 10.0 else "FAIL"
        if row["dev_pct"] > 10.0:
            all_ok = False
        max_dev = max(max_dev, row["dev_pct"])
        print(f"{row['label']:<32}  {row['daemon']:<6}  {row['upstream']:<8}   {row['dev_pct']:.2f}%  {flag}")
    print("-" * 72)
    print(f"max deviation: {max_dev:.2f}%  -> {'PASS' if all_ok else 'FAIL'} (threshold 10%)")

    # Write report
    report = Path(args.report_path)
    report.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        "---",
        "type: research",
        "phase: 5",
        "topic: count_tokens accuracy vs upstream",
        "date: 2026-04-24",
        "---",
        "",
        "# Phase 5 V2 — count_tokens accuracy probe",
        "",
        "## Method",
        "",
        "For each case, the Anthropic-shape payload is sent to the local daemon's",
        "`POST /v1/messages/count_tokens` endpoint to obtain `daemon_bpe`. A semantically",
        "equivalent `/responses`-shape payload is sent directly to the real upstream",
        "(`https://chatgpt.com/backend-api/codex/responses`), and the `response.completed`",
        "event's `response.usage.input_tokens` is read as `upstream_baseline`.",
        "",
        "Deviation = |daemon_bpe - upstream_baseline| / upstream_baseline.",
        "",
        "Auth loaded from `~/.codex/auth.json`. Transport: zstd-compressed POST with",
        "`accept: text/event-stream`, matching the daemon's own upstream path.",
        "",
        "## Results",
        "",
        "| # | Case | daemon_bpe | upstream_baseline | deviation | result |",
        "|--:|------|-----------:|------------------:|----------:|:-------|",
    ]
    for idx, row in enumerate(rows, start=1):
        if row.get("dev_pct") is None:
            lines.append(f"| {idx} | {row['label']} | {row['daemon']} | {row['upstream']} | — | FAIL ({row['daemon_err'] or '-'} / {row['upstream_err'] or '-'}) |")
        else:
            flag = "PASS" if row["dev_pct"] <= 10.0 else "FAIL"
            lines.append(f"| {idx} | {row['label']} | {row['daemon']} | {row['upstream']} | {row['dev_pct']:.2f}% | {flag} |")

    lines.append("")
    lines.append(f"**Max deviation:** {max_dev:.2f}%  —  **Overall:** {'PASS' if all_ok else 'FAIL'} (threshold 10%)")
    lines.append("")
    lines.append("## Notes")
    lines.append("")
    lines.append("- The daemon's `countablePayload` is constructed via the same IR codec path")
    lines.append("  used by `messageStartInputTokens`, so `count_tokens` and `message_start.usage.input_tokens`")
    lines.append("  are byte-identical (see `AnthropicBridge.swift:248-263`).")
    lines.append("- Semantic equivalence between Anthropic and /responses payloads is preserved")
    lines.append("  by mirroring `buildCountablePayload`'s transformation: system → instructions,")
    lines.append("  tool_use/tool_result → function_call/function_call_output.")
    report.write_text("\n".join(lines) + "\n")
    print(f"report written: {report}")

    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
