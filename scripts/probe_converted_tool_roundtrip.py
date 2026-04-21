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


def load_tools(path: Path, include_advisor: bool) -> list[dict]:
    capture = json.loads(path.read_text(encoding="utf-8"))
    body = json.loads(capture["body_utf8"])
    function_tools = [tool for tool in body["tools"] if tool.get("type", "function") == "function"]
    converted = [
        {
            "type": "function",
            "name": tool["name"],
            "description": tool["description"],
            "strict": False,
            "parameters": tool["input_schema"],
        }
        for tool in function_tools
    ]
    if include_advisor:
        for tool in body["tools"]:
            if tool.get("type") == "advisor_20260301":
                converted.append(json.loads(json.dumps(tool)))
                break
    return converted


def compress_payload(payload: dict) -> bytes:
    encoded = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    return zstd.ZstdCompressor().compress(encoded)


def deep_copy_json(value):
    return json.loads(json.dumps(value))


def build_first_request(base: dict, tools: list[dict], forced_tool_name: str) -> dict:
    payload = deep_copy_json(base)
    payload["tools"] = tools
    payload["tool_choice"] = {"type": "function", "name": forced_tool_name}
    payload["parallel_tool_calls"] = False
    payload["input"] = [
        {
            "type": "message",
            "role": "developer",
            "content": [
                {
                    "type": "input_text",
                    "text": "Use the provided function tool exactly once. Do not answer in plain text before the tool call.",
                }
            ],
        },
        {
            "type": "message",
            "role": "user",
            "content": [
                {
                    "type": "input_text",
                    "text": f"Call the {forced_tool_name} tool now. If it needs arguments, choose the smallest valid arguments that let the call proceed.",
                }
            ],
        },
    ]
    return payload


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


def extract_roundtrip_inputs(events: list[dict]) -> tuple[list[dict], dict, str]:
    output_items: list[dict] = []
    call_item: dict | None = None
    response_id: str | None = None
    for event in events:
        if event.get("type") == "response.output_item.done":
            item = event.get("item", {})
            if item.get("type") in {"reasoning", "function_call"}:
                output_items.append(item)
            if item.get("type") == "function_call":
                call_item = item
        if event.get("type") == "response.completed":
            response_id = event.get("response", {}).get("id")
    if call_item is None:
        raise RuntimeError("first response did not contain a completed function_call item")
    if response_id is None:
        raise RuntimeError("first response did not contain response.completed")
    return output_items, call_item, response_id


def build_second_request(base: dict, tools: list[dict], output_items: list[dict], call_item: dict, tool_output: str) -> dict:
    payload = deep_copy_json(base)
    payload["tools"] = tools
    payload["tool_choice"] = "auto"
    payload["parallel_tool_calls"] = False
    payload["input"] = output_items + [
        {
            "type": "function_call_output",
            "call_id": call_item["call_id"],
            "output": tool_output,
        }
    ]
    return payload


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


class ProbeHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    upstream_url = "https://chatgpt.com/backend-api/codex/responses"
    first_request_body = b""
    second_request_template: dict
    first_response_path: Path
    second_response_path: Path
    tool_output: str
    state_path: Path

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

        first_status, _, first_body = post_responses(self.upstream_url, self.first_request_body, passthrough_headers)
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

        events = parse_sse_events(first_body)
        output_items, call_item, response_id = extract_roundtrip_inputs(events)

        second_payload = build_second_request(
            self.second_request_template,
            self.second_request_template["tools"],
            output_items,
            call_item,
            self.tool_output,
        )
        self.state_path.write_text(
            json.dumps(
                {
                    "first_status": first_status,
                    "response_id": response_id,
                    "call_id": call_item["call_id"],
                    "function_name": call_item["name"],
                    "function_arguments": call_item["arguments"],
                    "second_input_item_types": [item.get("type") for item in second_payload["input"]],
                    "second_input_count": len(second_payload["input"]),
                },
                ensure_ascii=False,
                indent=2,
            ),
            encoding="utf-8",
        )

        second_status, second_headers, second_body = post_responses(
            self.upstream_url,
            compress_payload(second_payload),
            passthrough_headers,
        )
        self.second_response_path.write_bytes(second_body)

        if second_status >= 400:
            self.state_path.write_text(
                json.dumps(
                    {
                        "first_status": first_status,
                        "response_id": response_id,
                        "call_id": call_item["call_id"],
                        "function_name": call_item["name"],
                        "function_arguments": call_item["arguments"],
                        "second_input_item_types": [item.get("type") for item in second_payload["input"]],
                        "second_input_count": len(second_payload["input"]),
                        "second_status": second_status,
                        "second_error_body_utf8": second_body.decode("utf-8", errors="replace"),
                    },
                    ensure_ascii=False,
                    indent=2,
                ),
                encoding="utf-8",
            )

        self.send_response(second_status)
        self.send_header("content-type", second_headers.get("content-type", "text/event-stream"))
        self.send_header("content-length", str(len(second_body)))
        self.end_headers()
        self.wfile.write(second_body)
        self.wfile.flush()

    def log_message(self, fmt: str, *args) -> None:
        return


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--base-request-zst", required=True)
    parser.add_argument("--claude-request-json", required=True)
    parser.add_argument("--first-response-out", required=True)
    parser.add_argument("--second-response-out", required=True)
    parser.add_argument("--state-out", required=True)
    parser.add_argument("--forced-tool", default="Bash")
    parser.add_argument("--tool-output", default="success")
    parser.add_argument("--include-advisor", action="store_true")
    args = parser.parse_args()

    base = load_base_request(Path(args.base_request_zst))
    tools = load_tools(Path(args.claude_request_json), include_advisor=args.include_advisor)
    first_payload = build_first_request(base, tools, args.forced_tool)
    second_template = deep_copy_json(base)
    second_template["tools"] = deep_copy_json(tools)

    ProbeHandler.first_request_body = compress_payload(first_payload)
    ProbeHandler.second_request_template = second_template
    ProbeHandler.first_response_path = Path(args.first_response_out)
    ProbeHandler.second_response_path = Path(args.second_response_out)
    ProbeHandler.state_path = Path(args.state_out)
    ProbeHandler.tool_output = args.tool_output

    server = HTTPServer(("127.0.0.1", args.port), ProbeHandler)
    print(
        json.dumps(
            {
                "port": args.port,
                "forced_tool": args.forced_tool,
                "tool_count": len(tools),
                "include_advisor": args.include_advisor,
                "first_response_out": args.first_response_out,
                "second_response_out": args.second_response_out,
                "state_out": args.state_out,
            }
        )
    )
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
