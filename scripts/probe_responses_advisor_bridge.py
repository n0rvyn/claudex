#!/usr/bin/env python3

import argparse
import io
import json
import ssl
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import zstandard as zstd


def load_base_request(path: Path) -> dict:
    data = path.read_bytes()
    reader = zstd.ZstdDecompressor().stream_reader(io.BytesIO(data))
    return json.loads(reader.read())


def deep_copy_json(value):
    return json.loads(json.dumps(value))


def compress_payload(payload: dict) -> bytes:
    encoded = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    return zstd.ZstdCompressor().compress(encoded)


def parse_sse_events(body: bytes) -> list[dict]:
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


def extract_function_call(events: list[dict]) -> tuple[list[dict], dict]:
    output_items: list[dict] = []
    call_item: dict | None = None
    for event in events:
        if event.get("type") != "response.output_item.done":
            continue
        item = event.get("item", {})
        if item.get("type") in {"reasoning", "function_call"}:
            output_items.append(item)
        if item.get("type") == "function_call":
            call_item = item
    if call_item is None:
        raise RuntimeError("first upstream response did not emit a function_call")
    return output_items, call_item


def extract_text(events: list[dict]) -> str:
    parts: list[str] = []
    for event in events:
        if event.get("type") == "response.output_text.delta":
            parts.append(event.get("delta", ""))
    return "".join(parts)


def post_responses(url: str, request_body: bytes, headers: dict[str, str]) -> tuple[int, dict, bytes]:
    req = urllib.request.Request(url, data=request_body, method="POST")
    req.add_header("Authorization", headers["Authorization"])
    req.add_header("chatgpt-account-id", headers["chatgpt-account-id"])
    req.add_header("accept", "text/event-stream")
    req.add_header("content-type", "application/json")
    req.add_header("content-encoding", "zstd")
    req.add_header("user-agent", headers.get("user-agent", "modelbridge-probe"))
    ctx = ssl.create_default_context()
    try:
        with urllib.request.urlopen(req, context=ctx) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as err:
        return err.code, dict(err.headers), err.read()


def synthetic_advisor_tool() -> dict:
    return {
        "type": "function",
        "name": "advisor",
        "description": (
            "Ask a stronger planning advisor for concise strategic guidance. "
            "This tool takes no parameters and returns short advice text."
        ),
        "strict": False,
        "parameters": {
            "type": "object",
            "properties": {},
            "additionalProperties": False,
        },
    }


def build_first_request(base: dict, executor_model: str | None) -> dict:
    payload = deep_copy_json(base)
    if executor_model:
        payload["model"] = executor_model
    payload["tools"] = [synthetic_advisor_tool()]
    payload["tool_choice"] = {"type": "function", "name": "advisor"}
    payload["parallel_tool_calls"] = False
    payload["input"] = [
        {
            "type": "message",
            "role": "developer",
            "content": [
                {
                    "type": "input_text",
                    "text": "Use the advisor tool exactly once before answering.",
                }
            ],
        },
        {
            "type": "message",
            "role": "user",
            "content": [
                {
                    "type": "input_text",
                    "text": "Call advisor first, then answer with one short sentence.",
                }
            ],
        },
    ]
    return payload


def build_advisor_subrequest(base: dict, advisor_model: str, seed_text: str) -> dict:
    payload = deep_copy_json(base)
    payload["model"] = advisor_model
    payload["tools"] = []
    payload["tool_choice"] = "none"
    payload["parallel_tool_calls"] = False
    payload["input"] = [
        {
            "type": "message",
            "role": "developer",
            "content": [
                {
                    "type": "input_text",
                    "text": (
                        "You are a planning advisor. Return only a short guidance paragraph with the best next-step strategy."
                    ),
                }
            ],
        },
        {
            "type": "message",
            "role": "user",
            "content": [{"type": "input_text", "text": seed_text}],
        },
    ]
    return payload


def build_final_request(base: dict, output_items: list[dict], call_item: dict, advisor_text: str) -> dict:
    payload = deep_copy_json(base)
    payload["tools"] = [synthetic_advisor_tool()]
    payload["tool_choice"] = "auto"
    payload["parallel_tool_calls"] = False
    payload["input"] = output_items + [
        {
            "type": "function_call_output",
            "call_id": call_item["call_id"],
            "output": advisor_text,
        }
    ]
    return payload


class ProbeHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    upstream_url = "https://chatgpt.com/backend-api/codex/responses"
    first_payload: dict
    advisor_model: str
    state_path: Path
    first_response_path: Path
    advisor_response_path: Path
    final_response_path: Path

    def do_GET(self) -> None:
        self.send_response(404)
        self.end_headers()

    def do_POST(self) -> None:
        if self.path != "/responses":
            self.send_response(404)
            self.end_headers()
            return

        length = int(self.headers.get("content-length", "0"))
        _ = self.rfile.read(length)
        passthrough_headers = {
            "Authorization": self.headers["Authorization"],
            "chatgpt-account-id": self.headers["chatgpt-account-id"],
            "user-agent": self.headers.get("user-agent", "modelbridge-probe"),
        }

        first_status, _, first_body = post_responses(
            self.upstream_url,
            compress_payload(self.first_payload),
            passthrough_headers,
        )
        self.first_response_path.write_bytes(first_body)
        if first_status >= 400:
            self.state_path.write_text(
                json.dumps(
                    {
                        "first_status": first_status,
                        "first_error_body_utf8": first_body.decode("utf-8", errors="replace"),
                    },
                    ensure_ascii=False,
                    indent=2,
                ),
                encoding="utf-8",
            )
            self.send_response(first_status)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(first_body)))
            self.end_headers()
            self.wfile.write(first_body)
            self.wfile.flush()
            return

        first_events = parse_sse_events(first_body)
        output_items, call_item = extract_function_call(first_events)
        advisor_seed_text = "Provide concise strategic guidance for the current task."
        advisor_payload = build_advisor_subrequest(self.first_payload, self.advisor_model, advisor_seed_text)
        advisor_status, _, advisor_body = post_responses(
            self.upstream_url,
            compress_payload(advisor_payload),
            passthrough_headers,
        )
        self.advisor_response_path.write_bytes(advisor_body)
        if advisor_status >= 400:
            self.state_path.write_text(
                json.dumps(
                    {
                        "first_status": first_status,
                        "function_name": call_item["name"],
                        "advisor_status": advisor_status,
                        "advisor_error_body_utf8": advisor_body.decode("utf-8", errors="replace"),
                    },
                    ensure_ascii=False,
                    indent=2,
                ),
                encoding="utf-8",
            )
            self.send_response(advisor_status)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(advisor_body)))
            self.end_headers()
            self.wfile.write(advisor_body)
            self.wfile.flush()
            return

        advisor_text = extract_text(parse_sse_events(advisor_body)).strip()
        final_payload = build_final_request(self.first_payload, output_items, call_item, advisor_text)
        self.state_path.write_text(
            json.dumps(
                {
                    "first_status": first_status,
                    "function_name": call_item["name"],
                    "function_arguments": call_item["arguments"],
                    "advisor_status": advisor_status,
                    "advisor_model": self.advisor_model,
                    "advisor_text": advisor_text,
                    "final_input_item_types": [item.get("type") for item in final_payload["input"]],
                },
                ensure_ascii=False,
                indent=2,
            ),
            encoding="utf-8",
        )

        final_status, final_headers, final_body = post_responses(
            self.upstream_url,
            compress_payload(final_payload),
            passthrough_headers,
        )
        self.final_response_path.write_bytes(final_body)
        self.send_response(final_status)
        self.send_header("content-type", final_headers.get("content-type", "text/event-stream"))
        self.send_header("content-length", str(len(final_body)))
        self.end_headers()
        self.wfile.write(final_body)
        self.wfile.flush()

    def log_message(self, fmt: str, *args) -> None:
        return


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--base-request-zst", required=True)
    parser.add_argument("--state-out", required=True)
    parser.add_argument("--first-response-out", required=True)
    parser.add_argument("--advisor-response-out", required=True)
    parser.add_argument("--final-response-out", required=True)
    parser.add_argument("--executor-model")
    parser.add_argument("--advisor-model", default="gpt-5.4")
    args = parser.parse_args()

    base = load_base_request(Path(args.base_request_zst))
    ProbeHandler.first_payload = build_first_request(base, args.executor_model)
    ProbeHandler.advisor_model = args.advisor_model
    ProbeHandler.state_path = Path(args.state_out)
    ProbeHandler.first_response_path = Path(args.first_response_out)
    ProbeHandler.advisor_response_path = Path(args.advisor_response_out)
    ProbeHandler.final_response_path = Path(args.final_response_out)

    server = HTTPServer(("127.0.0.1", args.port), ProbeHandler)
    print(
        json.dumps(
            {
                "port": args.port,
                "executor_model": ProbeHandler.first_payload["model"],
                "advisor_model": args.advisor_model,
                "state_out": args.state_out,
            },
            ensure_ascii=False,
        )
    )
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
