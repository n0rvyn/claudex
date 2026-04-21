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


def maybe_decode_zstd(body: bytes, encoding: str | None) -> str | None:
    if encoding != "zstd":
        return None
    try:
        reader = zstd.ZstdDecompressor().stream_reader(io.BytesIO(body))
        return reader.read().decode("utf-8", errors="replace")
    except Exception:
        return None


def append_jsonl(path: Path, payload: dict) -> None:
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, ensure_ascii=False) + "\n")


def sse_bytes(event: str, data: dict) -> bytes:
    return (
        f"event: {event}\n"
        f"data: {json.dumps(data, separators=(',', ':'))}\n\n"
    ).encode("utf-8")


def forward_request(url: str, request_body: bytes, headers: dict[str, str]) -> tuple[int, dict[str, str], bytes]:
    req = urllib.request.Request(url, data=request_body, method="POST")
    req.add_header("Authorization", headers["Authorization"])
    req.add_header("chatgpt-account-id", headers["chatgpt-account-id"])
    req.add_header("accept", headers.get("accept", "text/event-stream"))
    req.add_header("content-type", headers.get("content-type", "application/json"))
    if "content-encoding" in headers:
        req.add_header("content-encoding", headers["content-encoding"])
    req.add_header("user-agent", headers.get("user-agent", "modelbridge-proxy"))
    ctx = ssl.create_default_context()
    try:
        with urllib.request.urlopen(req, context=ctx) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as err:
        return err.code, dict(err.headers), err.read()


class ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    upstream_url = "https://chatgpt.com/backend-api/codex/responses"
    log_dir: Path
    events_path: Path
    counter = 0
    responses_post_counter = 0
    inject_mode = ""
    inject_post_number = 0

    def do_GET(self) -> None:
        ProxyHandler.counter += 1
        index = ProxyHandler.counter
        append_jsonl(
            self.events_path,
            {
                "index": index,
                "method": "GET",
                "path": self.path,
                "headers": {key: value for key, value in self.headers.items()},
            },
        )
        self.send_response(404)
        self.send_header("content-length", "0")
        self.end_headers()

    def do_POST(self) -> None:
        ProxyHandler.counter += 1
        index = ProxyHandler.counter
        if self.path != "/responses":
            append_jsonl(
                self.events_path,
                {
                    "index": index,
                    "method": "POST",
                    "path": self.path,
                    "headers": {key: value for key, value in self.headers.items()},
                    "note": "unexpected_path",
                },
            )
            self.send_response(404)
            self.send_header("content-length", "0")
            self.end_headers()
            return

        ProxyHandler.responses_post_counter += 1
        responses_post_number = ProxyHandler.responses_post_counter
        length = int(self.headers.get("content-length", "0"))
        request_body = self.rfile.read(length)
        request_bin = self.log_dir / f"{index:03d}-request.bin"
        request_json = self.log_dir / f"{index:03d}-request.json"
        response_bin = self.log_dir / f"{index:03d}-response.bin"
        request_bin.write_bytes(request_body)

        request_record = {
            "index": index,
            "method": "POST",
            "path": self.path,
            "responses_post_number": responses_post_number,
            "headers": {key: value for key, value in self.headers.items()},
            "request_bin": str(request_bin),
        }
        decoded = maybe_decode_zstd(request_body, self.headers.get("content-encoding"))
        if decoded is not None:
            request_json.write_text(decoded, encoding="utf-8")
            request_record["request_json"] = str(request_json)
        append_jsonl(self.events_path, request_record)

        if (
            self.inject_mode
            and self.inject_post_number > 0
            and responses_post_number == self.inject_post_number
        ):
            self.respond_injected(index, responses_post_number)
            return

        passthrough_headers = {
            "Authorization": self.headers["Authorization"],
            "chatgpt-account-id": self.headers["chatgpt-account-id"],
            "accept": self.headers.get("accept", "text/event-stream"),
            "content-type": self.headers.get("content-type", "application/json"),
            "user-agent": self.headers.get("user-agent", "modelbridge-proxy"),
        }
        if "content-encoding" in self.headers:
            passthrough_headers["content-encoding"] = self.headers["content-encoding"]

        status, response_headers, response_body = forward_request(
            self.upstream_url,
            request_body,
            passthrough_headers,
        )
        response_bin.write_bytes(response_body)
        append_jsonl(
            self.events_path,
            {
                "index": index,
                "status": status,
                "response_bin": str(response_bin),
                "response_content_type": response_headers.get("content-type"),
            },
        )

        self.send_response(status)
        self.send_header("content-type", response_headers.get("content-type", "text/event-stream"))
        self.send_header("content-length", str(len(response_body)))
        self.end_headers()
        self.wfile.write(response_body)
        self.wfile.flush()

    def respond_injected(self, index: int, responses_post_number: int) -> None:
        if self.inject_mode == "json-400":
            self.send_json_error(index, responses_post_number, 400, "forced 400 from local /responses proxy")
            return
        if self.inject_mode == "json-500":
            self.send_json_error(index, responses_post_number, 500, "forced 500 from local /responses proxy")
            return
        if self.inject_mode == "malformed-sse":
            self.send_malformed_sse(index, responses_post_number)
            return
        if self.inject_mode == "truncated-sse":
            self.send_truncated_sse(index, responses_post_number)
            return
        raise AssertionError(f"unsupported inject_mode: {self.inject_mode}")

    def send_json_error(self, index: int, responses_post_number: int, status: int, detail: str) -> None:
        body = json.dumps({"detail": detail}).encode("utf-8")
        append_jsonl(
            self.events_path,
            {
                "index": index,
                "responses_post_number": responses_post_number,
                "response_kind": "json-error",
                "status": status,
                "body_utf8": body.decode("utf-8"),
            },
        )
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()

    def send_malformed_sse(self, index: int, responses_post_number: int) -> None:
        body = (
            b"event: response.created\n"
            b"data: {\"response\":{\"id\":\"resp_probe\",\"object\":\"response\",\"created_at\":0,\"status\":\"in_progress\",\"model\":\"gpt-5.4\",\"output\":[]}}\n\n"
            b"event: response.in_progress\n"
            b"data: {not-json}\n\n"
        )
        append_jsonl(
            self.events_path,
            {
                "index": index,
                "responses_post_number": responses_post_number,
                "response_kind": "malformed-sse",
                "body_utf8": body.decode("utf-8", errors="replace"),
            },
        )
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()

    def send_truncated_sse(self, index: int, responses_post_number: int) -> None:
        chunks = [
            sse_bytes(
                "response.created",
                {
                    "response": {
                        "id": "resp_probe",
                        "object": "response",
                        "created_at": 0,
                        "status": "in_progress",
                        "model": "gpt-5.4",
                        "output": [],
                    }
                },
            ),
            sse_bytes(
                "response.in_progress",
                {
                    "response": {
                        "id": "resp_probe",
                        "object": "response",
                        "created_at": 0,
                        "status": "in_progress",
                        "model": "gpt-5.4",
                        "output": [],
                    }
                },
            ),
        ]
        append_jsonl(
            self.events_path,
            {
                "index": index,
                "responses_post_number": responses_post_number,
                "response_kind": "truncated-sse",
                "chunk_count": len(chunks),
            },
        )
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "close")
        self.end_headers()
        for chunk in chunks:
            self.wfile.write(chunk)
            self.wfile.flush()
        self.close_connection = True

    def log_message(self, fmt: str, *args) -> None:
        return


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--log-dir", required=True)
    parser.add_argument(
        "--inject-mode",
        choices=["json-400", "json-500", "malformed-sse", "truncated-sse"],
        default="",
    )
    parser.add_argument("--inject-post-number", type=int, default=0)
    args = parser.parse_args()

    log_dir = Path(args.log_dir)
    log_dir.mkdir(parents=True, exist_ok=True)
    ProxyHandler.log_dir = log_dir
    ProxyHandler.events_path = log_dir / "events.jsonl"
    ProxyHandler.inject_mode = args.inject_mode
    ProxyHandler.inject_post_number = args.inject_post_number

    server = HTTPServer(("127.0.0.1", args.port), ProxyHandler)
    print(
        json.dumps(
            {
                "port": args.port,
                "log_dir": str(log_dir),
                "inject_mode": args.inject_mode,
                "inject_post_number": args.inject_post_number,
            }
        )
    )
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
