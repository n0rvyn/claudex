#!/usr/bin/env python3

import argparse
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


def load_events(path: Path) -> list[dict]:
    raw = path.read_text(encoding="utf-8")
    blocks = [block for block in raw.split("\n\n") if block.strip()]
    events: list[dict] = []
    for block in blocks:
        name = None
        data = None
        for line in block.splitlines():
            if line.startswith("event: "):
                name = line[len("event: ") :]
            elif line.startswith("data: "):
                data = json.loads(line[len("data: ") :])
        if name is None or data is None:
            raise ValueError(f"bad SSE block: {block!r}")
        events.append({"event": name, "data": data})
    return events


def keep_response_keys(payload: dict) -> dict:
    keep = {
        "id",
        "object",
        "created_at",
        "status",
        "error",
        "incomplete_details",
        "instructions",
        "metadata",
        "model",
        "output",
        "parallel_tool_calls",
        "previous_response_id",
        "reasoning",
        "service_tier",
        "store",
        "temperature",
        "text",
        "tool_choice",
        "tools",
        "top_p",
        "max_output_tokens",
        "max_tool_calls",
        "prompt_cache_key",
        "usage",
        "user",
    }
    return {key: value for key, value in payload.items() if key in keep}


def minimal_response(payload: dict, completed: bool) -> dict:
    base = {
        "id": payload["id"],
        "object": payload["object"],
        "created_at": payload["created_at"],
        "status": payload["status"],
        "model": payload["model"],
        "output": payload["output"],
    }
    if completed:
        usage = payload["usage"]
        base["usage"] = {
            "input_tokens": usage["input_tokens"],
            "output_tokens": usage["output_tokens"],
            "total_tokens": usage["total_tokens"],
        }
    return base


def minimal_item(item: dict) -> dict:
    content = []
    for part in item["content"]:
        next_part = {"type": part["type"]}
        if "text" in part:
            next_part["text"] = part["text"]
        content.append(next_part)
    return {
        "id": item["id"],
        "type": item["type"],
        "status": item["status"],
        "role": item["role"],
        "content": content,
    }


def transform_events(events: list[dict], mode: str) -> list[dict]:
    out: list[dict] = []
    for entry in events:
        event = entry["event"]
        data = json.loads(json.dumps(entry["data"]))

        if mode in {
            "drop_sequence_number",
            "drop_all_optional",
            "drop_reasoning_and_optional",
            "probe_minimal",
        }:
            data.pop("sequence_number", None)

        if mode in {"drop_reasoning_item", "drop_reasoning_and_optional", "probe_minimal"}:
            if event in {"response.output_item.added", "response.output_item.done"}:
                item = data.get("item", {})
                if item.get("type") == "reasoning":
                    continue

        if event == "response.content_part.added":
            part = data.get("part", {})
            if mode == "probe_minimal":
                data["part"] = {"type": part["type"], "text": part["text"]}
            if mode in {"drop_annotations", "drop_annotations_logprobs", "drop_reasoning_and_optional", "probe_minimal"}:
                part.pop("annotations", None)
            if mode in {"drop_annotations_logprobs", "drop_reasoning_and_optional", "probe_minimal"}:
                part.pop("logprobs", None)

        if event == "response.output_text.delta":
            if mode in {"drop_sequence_number", "drop_all_optional", "drop_reasoning_and_optional", "probe_minimal"}:
                data.pop("sequence_number", None)
            if mode in {"drop_annotations_logprobs", "drop_all_optional", "drop_reasoning_and_optional", "probe_minimal"}:
                data.pop("logprobs", None)
            if mode in {"drop_obfuscation", "drop_all_optional", "drop_reasoning_and_optional", "probe_minimal"}:
                data.pop("obfuscation", None)

        if event == "response.output_text.done":
            if mode == "probe_minimal":
                data.pop("sequence_number", None)
            if mode in {"drop_annotations_logprobs", "drop_all_optional", "drop_reasoning_and_optional", "probe_minimal"}:
                data.pop("logprobs", None)

        if event in {"response.output_item.added", "response.output_item.done"} and mode == "probe_minimal":
            data["item"] = minimal_item(data["item"])

        if event == "response.content_part.done" and mode == "probe_minimal":
            part = data["part"]
            data["part"] = {"type": part["type"], "text": part["text"]}

        if event in {"response.created", "response.in_progress", "response.completed"}:
            response = data.get("response", {})
            if mode == "probe_minimal":
                data["response"] = minimal_response(response, completed=(event == "response.completed"))
            if mode in {"drop_response_extras", "drop_all_optional", "drop_reasoning_and_optional"}:
                data["response"] = keep_response_keys(response)

        out.append({"event": event, "data": data})
    return out


def build_body(events: list[dict]) -> bytes:
    parts: list[str] = []
    for entry in events:
        parts.append(f"event: {entry['event']}\n")
        parts.append("data: ")
        parts.append(json.dumps(entry["data"], separators=(",", ":")))
        parts.append("\n\n")
    return "".join(parts).encode("utf-8")


class ReplayHandler(BaseHTTPRequestHandler):
    body = b""
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:
        if self.path.startswith("/responses"):
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self) -> None:
        if self.path != "/responses":
            self.send_response(404)
            self.end_headers()
            return

        length = int(self.headers.get("content-length", "0"))
        _ = self.rfile.read(length)

        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "keep-alive")
        self.end_headers()
        self.wfile.write(self.body)
        self.wfile.flush()

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write(fmt % args)
        sys.stderr.write("\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--response-file", required=True)
    parser.add_argument(
        "--mode",
        required=True,
        choices=[
            "baseline",
            "drop_sequence_number",
            "drop_reasoning_item",
            "drop_annotations",
            "drop_annotations_logprobs",
            "drop_obfuscation",
            "drop_response_extras",
            "drop_all_optional",
            "drop_reasoning_and_optional",
            "probe_minimal",
        ],
    )
    args = parser.parse_args()

    events = load_events(Path(args.response_file))
    transformed = transform_events(events, args.mode)
    ReplayHandler.body = build_body(transformed)

    server = HTTPServer(("127.0.0.1", args.port), ReplayHandler)
    print(
        json.dumps(
            {
                "port": args.port,
                "mode": args.mode,
                "response_file": args.response_file,
                "event_count": len(transformed),
            }
        )
    )
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
