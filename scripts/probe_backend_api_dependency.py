#!/usr/bin/env python3

import argparse
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


def append_jsonl(path: Path, payload: dict) -> None:
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, ensure_ascii=False) + "\n")


class BlockerHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    mode = ""
    log_dir: Path
    events_path: Path
    counter = 0

    def handle_any(self) -> None:
        BlockerHandler.counter += 1
        index = BlockerHandler.counter
        length = int(self.headers.get("content-length", "0"))
        body = self.rfile.read(length) if length else b""
        append_jsonl(
            self.events_path,
            {
                "index": index,
                "method": self.command,
                "path": self.path,
                "mode": self.mode,
                "headers": {key: value for key, value in self.headers.items()},
                "body_utf8": body.decode("utf-8", errors="replace"),
            },
        )

        if self.mode == "404":
            status = 404
            payload = {"error": "not found", "path": self.path}
        elif self.mode == "500":
            status = 500
            payload = {"error": "forced backend-api failure", "path": self.path}
        else:
            raise AssertionError(f"unsupported mode: {self.mode}")

        encoded = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)
        self.wfile.flush()

    def do_GET(self) -> None:
        self.handle_any()

    def do_POST(self) -> None:
        self.handle_any()

    def do_HEAD(self) -> None:
        self.handle_any()

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write(fmt % args)
        sys.stderr.write("\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--log-dir", required=True)
    parser.add_argument("--mode", required=True, choices=["404", "500"])
    args = parser.parse_args()

    log_dir = Path(args.log_dir)
    log_dir.mkdir(parents=True, exist_ok=True)
    BlockerHandler.mode = args.mode
    BlockerHandler.log_dir = log_dir
    BlockerHandler.events_path = log_dir / "events.jsonl"

    server = HTTPServer(("127.0.0.1", args.port), BlockerHandler)
    print(json.dumps({"port": args.port, "mode": args.mode, "log_dir": str(log_dir)}))
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
