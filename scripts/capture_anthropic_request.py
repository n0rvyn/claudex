#!/usr/bin/env python3

import argparse
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


class CaptureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    output_path: Path

    def do_POST(self) -> None:
        length = int(self.headers.get("content-length", "0"))
        body = self.rfile.read(length)

        record = {
            "method": self.command,
            "path": self.path,
            "headers": {key: value for key, value in self.headers.items()},
            "body_utf8": body.decode("utf-8", errors="replace"),
        }
        self.output_path.write_text(
            json.dumps(record, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )

        if self.path.startswith("/v1/messages/count_tokens"):
            payload = {"input_tokens": 1}
            encoded = json.dumps(payload).encode("utf-8")
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
            self.wfile.flush()
            return

        payload = {
            "type": "error",
            "error": {
                "type": "invalid_request_error",
                "message": "capture complete",
            },
        }
        encoded = json.dumps(payload).encode("utf-8")
        self.send_response(400)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)
        self.wfile.flush()

    def log_message(self, fmt: str, *args) -> None:
        return


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    CaptureHandler.output_path = Path(args.output)
    server = HTTPServer(("127.0.0.1", args.port), CaptureHandler)
    print(
        json.dumps(
            {
                "port": args.port,
                "output": args.output,
            }
        )
    )
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
