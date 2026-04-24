#!/usr/bin/env python3
"""
Probe image wire shapes + include.reasoning.summary + tool_result image path.

Runs 4 rows against the real Codex ChatGPT endpoint:
- Row A: input_image in user message content (base64 1x1 PNG)
- Row B: view_image function injected via tools + forced tool_choice
- Row C: include: ["reasoning.encrypted_content", "reasoning.summary"]
- Row D: function_call + function_call_output + user message with input_image

Each row reports: status, turn_outcome (completed/failed/timeout/parse_error), snippet.
Row C additionally reports reasoning_summary_found (bool).
Row B additionally reports whether view_image call was actually dispatched.

Usage: python3 scripts/probe_image_wire.py --out docs/research/2026-04-22-image-wire-probe.md
"""
from __future__ import annotations

import argparse
import json
import ssl
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

import zstandard as zstd

sys.path.insert(0, str(Path(__file__).parent))
from _probe_common import UPSTREAM_URL, load_auth, redact

# Smallest possible PNG: 1x1 transparent pixel, 67 bytes.
TINY_PNG_BASE64 = (
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
)
TINY_PNG_DATA_URL = f"data:image/png;base64,{TINY_PNG_BASE64}"

VIEW_IMAGE_FUNCTION_SCHEMA = {
    "type": "function",
    "name": "view_image",
    "description": "Use this function to view an image by URL or path.",
    "strict": False,
    "parameters": {
        "type": "object",
        "properties": {
            "path": {"type": "string", "description": "URL or path to the image."}
        },
        "required": ["path"],
        "additionalProperties": False,
    },
}


def base_payload_no_image() -> dict[str, Any]:
    return {
        "model": "gpt-5.4",
        "instructions": "",
        "input": [],
        "tools": [],
        "tool_choice": "auto",
        "parallel_tool_calls": False,
        "reasoning": {"effort": "xhigh"},
        "store": False,
        "stream": True,
        "include": ["reasoning.encrypted_content"],
        "service_tier": "priority",
        "prompt_cache_key": "probe-image-wire",
        "text": {"verbosity": "low"},
    }


def post_and_consume(
    payload: dict[str, Any], access_token: str, account_id: str, timeout: int = 45
) -> dict[str, Any]:
    """
    POST (zstd-compressed) and read full SSE stream.
    Returns: status, turn_outcome (completed/failed/no_terminal), events_seen (list of event types), snippet.
    """
    raw = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    body = zstd.ZstdCompressor().compress(raw)
    req = urllib.request.Request(UPSTREAM_URL, data=body, method="POST")
    req.add_header("Authorization", f"Bearer {access_token}")
    req.add_header("chatgpt-account-id", account_id)
    req.add_header("accept", "text/event-stream")
    req.add_header("content-type", "application/json")
    req.add_header("content-encoding", "zstd")
    req.add_header("user-agent", "modelbridge-probe/phase3")
    try:
        with urllib.request.urlopen(
            req, context=ssl.create_default_context(), timeout=timeout
        ) as r:
            raw_body = r.read()
            text = raw_body.decode("utf-8", errors="replace")
            return analyze_sse(status=r.status, text=text)
    except urllib.error.HTTPError as e:
        text = e.read().decode("utf-8", errors="replace")
        return {
            "status": e.code,
            "turn_outcome": "http_error",
            "events_seen": [],
            "snippet": redact(text[:800]),
            "error": redact(str(e)),
        }
    except Exception as e:
        return {
            "status": None,
            "turn_outcome": "transport_error",
            "events_seen": [],
            "snippet": "",
            "error": redact(str(e)),
        }


def analyze_sse(status: int, text: str) -> dict[str, Any]:
    """
    Parse SSE text, extract event types and terminal turn outcome.
    Also surfaces whether reasoning summary field appeared in any reasoning item.
    """
    events_seen: list[str] = []
    turn_outcome = "no_terminal"
    reasoning_summary_found = False
    view_image_called = False
    function_call_names: list[str] = []

    for line in text.split("\n"):
        line = line.strip()
        if not line.startswith("data:"):
            continue
        data_str = line[len("data:") :].strip()
        if not data_str or data_str == "[DONE]":
            continue
        try:
            obj = json.loads(data_str)
        except json.JSONDecodeError:
            continue
        etype = obj.get("type", "")
        if etype and etype not in events_seen:
            events_seen.append(etype)
        if etype == "response.completed":
            turn_outcome = "completed"
        if etype == "response.failed":
            turn_outcome = "failed"
        if etype == "response.output_item.done":
            item = obj.get("item") or {}
            if item.get("type") == "reasoning":
                if "summary" in item:
                    summary_val = item.get("summary")
                    # summary can be string, list of {type:"summary_text", text:"..."}, or other
                    if summary_val is not None and summary_val != "" and summary_val != []:
                        reasoning_summary_found = True
            if item.get("type") == "function_call":
                name = item.get("name", "")
                function_call_names.append(name)
                if name == "view_image":
                    view_image_called = True

    return {
        "status": status,
        "turn_outcome": turn_outcome,
        "events_seen": events_seen,
        "reasoning_summary_found": reasoning_summary_found,
        "view_image_called": view_image_called,
        "function_call_names": function_call_names,
        "snippet": redact(text[:800]),
    }


def row_a_input_image() -> dict[str, Any]:
    p = base_payload_no_image()
    p["input"] = [
        {
            "type": "message",
            "role": "user",
            "content": [
                {"type": "input_text", "text": "Describe this image in one word."},
                {"type": "input_image", "image_url": TINY_PNG_DATA_URL},
            ],
        }
    ]
    return p


def row_b_view_image_function() -> dict[str, Any]:
    p = base_payload_no_image()
    p["tools"] = [VIEW_IMAGE_FUNCTION_SCHEMA]
    p["tool_choice"] = {"type": "function", "name": "view_image"}
    p["input"] = [
        {
            "type": "message",
            "role": "user",
            "content": [
                {
                    "type": "input_text",
                    "text": "Please call view_image with path 'test.png' to examine the image.",
                }
            ],
        }
    ]
    return p


def row_c_reasoning_summary_include() -> dict[str, Any]:
    p = base_payload_no_image()
    p["include"] = ["reasoning.encrypted_content", "reasoning.summary"]
    p["input"] = [
        {
            "type": "message",
            "role": "user",
            "content": [{"type": "input_text", "text": "Reply OK."}],
        }
    ]
    return p


def row_d_tool_result_then_image() -> dict[str, Any]:
    p = base_payload_no_image()
    p["tools"] = [VIEW_IMAGE_FUNCTION_SCHEMA]
    # Construct: prior function_call (from history) + its function_call_output (also history)
    # + a new user message containing input_image (the tool's returned image surfaced as user content).
    p["input"] = [
        {
            "type": "message",
            "role": "user",
            "content": [
                {"type": "input_text", "text": "Please view the attached screenshot."}
            ],
        },
        {
            "type": "function_call",
            "call_id": "call_probe_d_1",
            "name": "view_image",
            "arguments": json.dumps({"path": "screenshot.png"}),
        },
        {
            "type": "function_call_output",
            "call_id": "call_probe_d_1",
            "output": "[image follows in the next user message]",
        },
        {
            "type": "message",
            "role": "user",
            "content": [
                {"type": "input_text", "text": "Here is the image:"},
                {"type": "input_image", "image_url": TINY_PNG_DATA_URL},
            ],
        },
    ]
    return p


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", help="Output markdown report path", required=False)
    args = ap.parse_args()

    access_token, account_id = load_auth()

    rows: list[tuple[str, str, dict[str, Any]]] = [
        ("A", "input_image in user message", row_a_input_image()),
        ("B", "view_image function_call injection", row_b_view_image_function()),
        (
            "C",
            "include: reasoning.encrypted_content + reasoning.summary",
            row_c_reasoning_summary_include(),
        ),
        (
            "D",
            "function_call + function_call_output + user input_image",
            row_d_tool_result_then_image(),
        ),
    ]

    results: list[dict[str, Any]] = []
    for row_id, label, payload in rows:
        print(f"Running Row {row_id}: {label} ...", file=sys.stderr)
        r = post_and_consume(payload, access_token, account_id)
        r["row_id"] = row_id
        r["label"] = label
        results.append(r)
        print(json.dumps({"row": row_id, **{k: v for k, v in r.items() if k != "snippet"}}, ensure_ascii=False))

    # Conclusion derivation
    row_a = next(r for r in results if r["row_id"] == "A")
    row_b = next(r for r in results if r["row_id"] == "B")
    row_c = next(r for r in results if r["row_id"] == "C")
    row_d = next(r for r in results if r["row_id"] == "D")

    image_path_choice: str
    if row_a.get("turn_outcome") == "completed":
        image_path_choice = "input_image (Row A verified)"
    elif row_b.get("turn_outcome") == "completed" and row_b.get("view_image_called"):
        image_path_choice = "view_image function (Row B verified)"
    else:
        image_path_choice = "NEITHER — fallback path required"

    summary_ok = (
        row_c.get("turn_outcome") == "completed" and row_c.get("reasoning_summary_found")
    )
    summary_conclusion = (
        "reasoning.summary supported"
        if summary_ok
        else "reasoning.summary NOT verified (either turn failed or summary field absent)"
    )
    tool_result_image_conclusion = (
        "tool_result image path works (Row D completed)"
        if row_d.get("turn_outcome") == "completed"
        else "tool_result image path NOT accepted"
    )

    if args.out:
        out = Path(args.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        lines = ["# Image Wire Shape + include.reasoning.summary Probe Report — 2026-04-22", ""]
        lines.append("## Rows")
        lines.append("")
        lines.append("| Row | Label | status | turn_outcome | extra |")
        lines.append("|---|---|---|---|---|")
        for r in results:
            extra_parts = []
            if r["row_id"] == "B":
                extra_parts.append(f"view_image_called={r.get('view_image_called')}")
                extra_parts.append(f"function_call_names={r.get('function_call_names')}")
            if r["row_id"] == "C":
                extra_parts.append(f"reasoning_summary_found={r.get('reasoning_summary_found')}")
            if r.get("error"):
                extra_parts.append(f"error={r['error'][:100]}")
            extra = "; ".join(extra_parts) if extra_parts else "—"
            lines.append(
                f"| {r['row_id']} | {r['label']} | {r.get('status')} | {r.get('turn_outcome')} | {extra} |"
            )

        lines.append("")
        lines.append("## Snippets")
        for r in results:
            lines.append(f"\n### Row {r['row_id']} snippet (first 800 chars, redacted)")
            lines.append("```")
            lines.append(r.get("snippet", ""))
            lines.append("```")

        lines.append("")
        lines.append("## Events seen per row")
        for r in results:
            lines.append(f"- **Row {r['row_id']}**: {r.get('events_seen')}")

        lines.append("")
        lines.append("## Conclusion")
        lines.append("")
        lines.append(f"- **Image wire shape for Phase 3a**: {image_path_choice}")
        lines.append(f"- **reasoning.summary include**: {summary_conclusion}")
        lines.append(f"- **tool_result image path (Row D)**: {tool_result_image_conclusion}")
        out.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"\nReport written to {out}", file=sys.stderr)


if __name__ == "__main__":
    raise SystemExit(main())
