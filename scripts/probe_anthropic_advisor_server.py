#!/usr/bin/env python3

import argparse
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


def sse_event(name: str, payload: dict) -> bytes:
    return f"event: {name}\ndata: {json.dumps(payload, ensure_ascii=False)}\n\n".encode("utf-8")


def build_advisor_stream(model: str, assistant_text: str, advisor_text: str) -> bytes:
    message_id = "msg_probe_advisor_01"
    tool_use_id = "srvtoolu_probe_advisor_01"
    chunks: list[bytes] = [
        sse_event(
            "message_start",
            {
                "type": "message_start",
                "message": {
                    "id": message_id,
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
                "delta": {"type": "text_delta", "text": "Let me consult the advisor first."},
            },
        ),
        sse_event("content_block_stop", {"type": "content_block_stop", "index": 0}),
        sse_event(
            "content_block_start",
            {
                "type": "content_block_start",
                "index": 1,
                "content_block": {
                    "type": "server_tool_use",
                    "id": tool_use_id,
                    "name": "advisor",
                    "input": {},
                },
            },
        ),
        sse_event("content_block_stop", {"type": "content_block_stop", "index": 1}),
        sse_event(
            "content_block_start",
            {
                "type": "content_block_start",
                "index": 2,
                "content_block": {
                    "type": "advisor_tool_result",
                    "tool_use_id": tool_use_id,
                    "content": {
                        "type": "advisor_result",
                        "text": advisor_text,
                    },
                },
            },
        ),
        sse_event("content_block_stop", {"type": "content_block_stop", "index": 2}),
        sse_event(
            "content_block_start",
            {
                "type": "content_block_start",
                "index": 3,
                "content_block": {"type": "text", "text": ""},
            },
        ),
        sse_event(
            "content_block_delta",
            {
                "type": "content_block_delta",
                "index": 3,
                "delta": {"type": "text_delta", "text": assistant_text},
            },
        ),
        sse_event("content_block_stop", {"type": "content_block_stop", "index": 3}),
        sse_event(
            "message_delta",
            {
                "type": "message_delta",
                "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                "usage": {
                    "output_tokens": 16,
                    "iterations": [
                        {
                            "type": "message",
                            "input_tokens": 1,
                            "cache_read_input_tokens": 0,
                            "cache_creation_input_tokens": 0,
                            "output_tokens": 4,
                        },
                        {
                            "type": "advisor_message",
                            "model": "claude-opus-4-7",
                            "input_tokens": 1,
                            "cache_read_input_tokens": 0,
                            "cache_creation_input_tokens": 0,
                            "output_tokens": 8,
                        },
                        {
                            "type": "message",
                            "input_tokens": 1,
                            "cache_read_input_tokens": 0,
                            "cache_creation_input_tokens": 0,
                            "output_tokens": 4,
                        },
                    ],
                },
            },
        ),
        sse_event("message_stop", {"type": "message_stop"}),
    ]
    return b"".join(chunks)


def build_plain_text_stream(model: str, text: str) -> bytes:
    chunks: list[bytes] = [
        sse_event(
            "message_start",
            {
                "type": "message_start",
                "message": {
                    "id": "msg_probe_followup_01",
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
    return b"".join(chunks)


class ProbeHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    requests_path: Path
    title_text: str
    advisor_text: str
    first_reply_text: str
    followup_reply_text: str
    request_count = 0

    def do_POST(self) -> None:
        length = int(self.headers.get("content-length", "0"))
        body = self.rfile.read(length)

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
            self.end_headers()
            return

        self.__class__.request_count += 1
        request_number = self.__class__.request_count

        record = {
            "request_number": request_number,
            "method": self.command,
            "path": self.path,
            "headers": {key: value for key, value in self.headers.items()},
            "body_utf8": body.decode("utf-8", errors="replace"),
        }
        with self.requests_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, ensure_ascii=False))
            handle.write("\n")

        request_json = json.loads(record["body_utf8"])
        model = request_json.get("model", "claude-sonnet-4-6")
        if request_number == 1:
            payload = build_plain_text_stream(model, self.title_text)
        elif request_number == 2:
            payload = build_advisor_stream(model, self.first_reply_text, self.advisor_text)
        else:
            payload = build_plain_text_stream(model, self.followup_reply_text)

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
    parser.add_argument("--requests-out", required=True)
    parser.add_argument("--title-text", default='{"title":"Advisor probe"}')
    parser.add_argument("--advisor-text", default="Break the work into small verified steps.")
    parser.add_argument("--first-reply-text", default="Advisor consulted. Final answer from the first turn.")
    parser.add_argument("--followup-reply-text", default="Follow-up answer after prior advisor context was preserved.")
    args = parser.parse_args()

    requests_path = Path(args.requests_out)
    requests_path.write_text("", encoding="utf-8")

    ProbeHandler.requests_path = requests_path
    ProbeHandler.title_text = args.title_text
    ProbeHandler.advisor_text = args.advisor_text
    ProbeHandler.first_reply_text = args.first_reply_text
    ProbeHandler.followup_reply_text = args.followup_reply_text
    ProbeHandler.request_count = 0

    server = HTTPServer(("127.0.0.1", args.port), ProbeHandler)
    print(
        json.dumps(
            {
                "port": args.port,
                "requests_out": args.requests_out,
            },
            ensure_ascii=False,
        )
    )
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
