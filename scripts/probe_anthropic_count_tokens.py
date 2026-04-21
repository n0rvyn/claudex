#!/usr/bin/env python3

import argparse
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


def append_jsonl(path: Path, payload: dict) -> None:
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, ensure_ascii=False) + "\n")


def sse_event(name: str, payload: dict) -> bytes:
    return f"event: {name}\ndata: {json.dumps(payload, ensure_ascii=False)}\n\n".encode("utf-8")


def build_text_stream(model: str, text: str) -> bytes:
    return b"".join(
        [
            sse_event(
                "message_start",
                {
                    "type": "message_start",
                    "message": {
                        "id": "msg_probe_count_tokens_01",
                        "type": "message",
                        "role": "assistant",
                        "model": model,
                        "content": [],
                        "stop_reason": None,
                        "stop_sequence": None,
                        "usage": {"input_tokens": 1, "output_tokens": 1},
                    },
                },
            ),
            sse_event(
                "content_block_start",
                {
                    "type": "content_block_start",
                    "index": 0,
                    "content_block": {"type": "text", "text": ""},
                },
            ),
            sse_event(
                "content_block_delta",
                {
                    "type": "content_block_delta",
                    "index": 0,
                    "delta": {"type": "text_delta", "text": text},
                },
            ),
            sse_event("content_block_stop", {"type": "content_block_stop", "index": 0}),
            sse_event(
                "message_delta",
                {
                    "type": "message_delta",
                    "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                    "usage": {"output_tokens": 8},
                },
            ),
            sse_event("message_stop", {"type": "message_stop"}),
        ]
    )


class ProbeHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    events_path: Path
    reply_text: str
    counter = 0

    def do_POST(self) -> None:
        ProbeHandler.counter += 1
        index = ProbeHandler.counter
        length = int(self.headers.get("content-length", "0"))
        body = self.rfile.read(length)
        record = {
            "index": index,
            "method": self.command,
            "path": self.path,
            "headers": {key: value for key, value in self.headers.items()},
            "body_utf8": body.decode("utf-8", errors="replace"),
        }
        append_jsonl(self.events_path, record)

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

        if not self.path.startswith("/v1/messages"):
            self.send_response(404)
            self.send_header("content-length", "0")
            self.end_headers()
            return

        model = "claude-sonnet-4-6"
        try:
            request_json = json.loads(record["body_utf8"])
            model = request_json.get("model", model)
        except json.JSONDecodeError:
            pass

        payload = build_text_stream(model, self.reply_text)
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "close")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        self.wfile.flush()

    def log_message(self, fmt: str, *args) -> None:
        return


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--events-out", required=True)
    parser.add_argument("--reply-text", default="COUNTTOKENS_OK")
    args = parser.parse_args()

    events_path = Path(args.events_out)
    events_path.parent.mkdir(parents=True, exist_ok=True)
    events_path.write_text("", encoding="utf-8")

    ProbeHandler.events_path = events_path
    ProbeHandler.reply_text = args.reply_text
    ProbeHandler.counter = 0

    server = HTTPServer(("127.0.0.1", args.port), ProbeHandler)
    print(json.dumps({"port": args.port, "events_out": str(events_path)}, ensure_ascii=False))
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
