#!/usr/bin/env python3

import argparse
import io
import json
import ssl
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import zstandard as zstd


def load_base_request(path: Path) -> dict:
    data = path.read_bytes()
    reader = zstd.ZstdDecompressor().stream_reader(io.BytesIO(data))
    return json.loads(reader.read())


def load_converted_tools(path: Path, source: str) -> list[dict]:
    body = json.loads(json.loads(path.read_text(encoding="utf-8"))["body_utf8"])
    tools = body["tools"]
    if source == "bare":
        tools = [tool for tool in tools if tool.get("type", "function") == "function"]
    else:
        tools = [tool for tool in tools if tool.get("type", "function") == "function"]
    return [
        {
            "type": "function",
            "name": tool["name"],
            "description": tool["description"],
            "strict": False,
            "parameters": tool["input_schema"],
        }
        for tool in tools
    ]


def compress_payload(payload: dict) -> bytes:
    encoded = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    return zstd.ZstdCompressor().compress(encoded)


class ForwardHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    upstream_url = "https://chatgpt.com/backend-api/codex/responses"
    request_body = b""

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

        req = urllib.request.Request(
            self.upstream_url,
            data=self.request_body,
            method="POST",
        )
        req.add_header("Authorization", self.headers["Authorization"])
        req.add_header("chatgpt-account-id", self.headers["chatgpt-account-id"])
        req.add_header("accept", "text/event-stream")
        req.add_header("content-type", "application/json")
        req.add_header("content-encoding", "zstd")
        req.add_header("user-agent", self.headers.get("user-agent", "modelbridge-probe"))

        ctx = ssl.create_default_context()
        with urllib.request.urlopen(req, context=ctx) as resp:
            body = resp.read()
            self.send_response(resp.status)
            self.send_header("content-type", resp.headers.get("content-type", "text/event-stream"))
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            self.wfile.flush()

    def log_message(self, fmt: str, *args) -> None:
        return


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--base-request-zst", required=True)
    parser.add_argument("--claude-request-json", required=True)
    parser.add_argument("--source", choices=["bare", "full"], default="full")
    args = parser.parse_args()

    base = load_base_request(Path(args.base_request_zst))
    base["tools"] = load_converted_tools(Path(args.claude_request_json), args.source)
    ForwardHandler.request_body = compress_payload(base)

    server = HTTPServer(("127.0.0.1", args.port), ForwardHandler)
    print(
        json.dumps(
            {
                "port": args.port,
                "source": args.source,
                "tool_count": len(base["tools"]),
            }
        )
    )
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
