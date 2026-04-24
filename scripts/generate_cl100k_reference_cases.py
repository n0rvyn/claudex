#!/usr/bin/env python3

import argparse
import base64
import json
from pathlib import Path

import tiktoken
from tiktoken_ext.openai_public import cl100k_base


FIXTURE_INPUTS = [
    "hello",
    "Run a bash command",
    '{"additionalProperties":false,"properties":{"command":{"type":"string"}},"required":["command"],"type":"object"}',
]


def load_mergeable_ranks(path: Path) -> dict[bytes, int]:
    mergeable_ranks: dict[bytes, int] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        token_b64, rank_text = raw_line.split(" ")
        mergeable_ranks[base64.b64decode(token_b64)] = int(rank_text)
    return mergeable_ranks


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--encoding-file", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    encoding_file = Path(args.encoding_file)
    output_file = Path(args.out)

    base = cl100k_base()
    encoding = tiktoken.Encoding(
        name="cl100k_base_vendored",
        pat_str=base["pat_str"],
        mergeable_ranks=load_mergeable_ranks(encoding_file),
        special_tokens=base["special_tokens"],
    )

    fixtures = []
    for text in FIXTURE_INPUTS:
        token_ids = encoding.encode_ordinary(text)
        fixtures.append(
            {
                "input": text,
                "token_ids": token_ids,
                "count": len(token_ids),
            }
        )

    output_file.parent.mkdir(parents=True, exist_ok=True)
    output_file.write_text(json.dumps(fixtures, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
