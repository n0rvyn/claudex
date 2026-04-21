#!/usr/bin/env python3

import argparse
import io
import json
import sys
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


class ProbeHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    mode = ""
    log_dir: Path
    events_path: Path
    counter = 0

    def do_GET(self) -> None:
        ProbeHandler.counter += 1
        index = ProbeHandler.counter
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
        ProbeHandler.counter += 1
        index = ProbeHandler.counter

        length = int(self.headers.get("content-length", "0"))
        request_body = self.rfile.read(length)
        request_bin = self.log_dir / f"{index:03d}-request.bin"
        request_json = self.log_dir / f"{index:03d}-request.json"
        request_bin.write_bytes(request_body)

        record = {
            "index": index,
            "method": "POST",
            "path": self.path,
            "mode": self.mode,
            "headers": {key: value for key, value in self.headers.items()},
            "request_bin": str(request_bin),
        }
        decoded = maybe_decode_zstd(request_body, self.headers.get("content-encoding"))
        if decoded is not None:
            request_json.write_text(decoded, encoding="utf-8")
            record["request_json"] = str(request_json)
        append_jsonl(self.events_path, record)

        if self.path != "/responses":
            self.send_response(404)
            self.send_header("content-length", "0")
            self.end_headers()
            return

        if self.mode == "json-400":
            self.send_json_error(index, 400, "forced 400 from local /responses probe")
            return
        if self.mode == "json-500":
            self.send_json_error(index, 500, "forced 500 from local /responses probe")
            return
        if self.mode == "malformed-sse":
            self.send_malformed_sse(index)
            return
        if self.mode == "truncated-sse":
            self.send_truncated_sse(index)
            return

        raise AssertionError(f"unsupported mode: {self.mode}")

    def send_json_error(self, index: int, status: int, detail: str) -> None:
        body = json.dumps({"detail": detail}).encode("utf-8")
        append_jsonl(
            self.events_path,
            {
                "index": index,
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

    def send_malformed_sse(self, index: int) -> None:
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

    def send_truncated_sse(self, index: int) -> None:
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
        sys.stderr.write(fmt % args)
        sys.stderr.write("\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--log-dir", required=True)
    parser.add_argument(
        "--mode",
        required=True,
        choices=["json-400", "json-500", "malformed-sse", "truncated-sse"],
    )
    args = parser.parse_args()

    log_dir = Path(args.log_dir)
    log_dir.mkdir(parents=True, exist_ok=True)
    ProbeHandler.mode = args.mode
    ProbeHandler.log_dir = log_dir
    ProbeHandler.events_path = log_dir / "events.jsonl"

    server = HTTPServer(("127.0.0.1", args.port), ProbeHandler)
    print(json.dumps({"port": args.port, "mode": args.mode, "log_dir": str(log_dir)}))
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
