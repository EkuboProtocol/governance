#!/usr/bin/env python3
"""Encode and decode Starknet Governor call lists for the interface Import action."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


FIELD_PRIME = 2**251 + 17 * 2**192 + 1
MAX_FELT = FIELD_PRIME - 1
MAX_U128 = 2**128 - 1


class InputError(ValueError):
    """Raised when proposal call data is structurally invalid."""


def read_text(path: str) -> str:
    if path == "-":
        return sys.stdin.read()
    return Path(path).read_text(encoding="utf-8")


def parse_integer(value: Any, label: str, maximum: int = MAX_FELT) -> int:
    if isinstance(value, bool):
        raise InputError(f"{label} must be an integer, not a boolean")
    if isinstance(value, int):
        parsed = value
    elif isinstance(value, str):
        stripped = value.strip()
        if not stripped:
            raise InputError(f"{label} is empty")
        try:
            parsed = int(stripped, 16 if stripped.lower().startswith("0x") else 10)
        except ValueError as exc:
            raise InputError(f"{label} is not a decimal or 0x-prefixed integer") from exc
    else:
        raise InputError(f"{label} must be an integer or string")

    if parsed < 0:
        raise InputError(f"{label} must not be negative")
    if parsed > maximum:
        raise InputError(f"{label} exceeds its maximum value")
    return parsed


def to_hex(value: int) -> str:
    return hex(value)


def get_call_field(call: dict[str, Any], index: int, *names: str) -> Any:
    present = [name for name in names if name in call]
    if len(present) != 1:
        joined = ", ".join(names)
        raise InputError(f"call[{index}] must contain exactly one of: {joined}")
    return call[present[0]]


def normalize_calls(document: Any) -> list[dict[str, Any]]:
    calls = document.get("calls") if isinstance(document, dict) else document
    if not isinstance(calls, list):
        raise InputError("input JSON must be a call array or an object with a calls array")
    if len(calls) > MAX_U128:
        raise InputError("call count exceeds u128")

    normalized: list[dict[str, Any]] = []
    for index, call in enumerate(calls):
        if not isinstance(call, dict):
            raise InputError(f"call[{index}] must be an object")

        address = parse_integer(
            get_call_field(call, index, "contract_address", "contractAddress", "to"),
            f"call[{index}].contract_address",
        )
        selector = parse_integer(
            get_call_field(call, index, "selector"),
            f"call[{index}].selector",
        )
        calldata = call.get("calldata", [])
        if isinstance(calldata, str):
            calldata = (
                [part.strip() for part in calldata.split(",") if part.strip()]
                if calldata.strip()
                else []
            )
        if not isinstance(calldata, list):
            raise InputError(f"call[{index}].calldata must be an array or comma-delimited string")
        if len(calldata) > MAX_U128:
            raise InputError(f"call[{index}].calldata length exceeds u128")

        normalized.append(
            {
                "contract_address": address,
                "selector": selector,
                "calldata": [
                    parse_integer(value, f"call[{index}].calldata[{calldata_index}]")
                    for calldata_index, value in enumerate(calldata)
                ],
            }
        )
    return normalized


def encode_calls(calls: list[dict[str, Any]]) -> str:
    words = [to_hex(len(calls))]
    for call in calls:
        calldata = call["calldata"]
        words.extend(
            [
                to_hex(call["contract_address"]),
                to_hex(call["selector"]),
                to_hex(len(calldata)),
                *(to_hex(value) for value in calldata),
            ]
        )
    return ",".join(words)


def decode_line(line: str) -> list[dict[str, Any]]:
    raw_words = [word.strip() for word in line.strip().split(",")]
    if not raw_words or raw_words == [""]:
        raise InputError("import line is empty")
    if any(not word for word in raw_words):
        raise InputError("import line contains an empty value")

    words = [
        parse_integer(word, f"word[{index}]")
        for index, word in enumerate(raw_words)
    ]
    expected_calls = parse_integer(words[0], "call_count", MAX_U128)
    calls: list[dict[str, Any]] = []
    cursor = 1

    for call_index in range(expected_calls):
        if cursor + 3 > len(words):
            raise InputError(f"call[{call_index}] header is truncated")
        address = words[cursor]
        selector = words[cursor + 1]
        calldata_length = parse_integer(
            words[cursor + 2], f"call[{call_index}].calldata_length", MAX_U128
        )
        cursor += 3
        end = cursor + calldata_length
        if end > len(words):
            raise InputError(f"call[{call_index}].calldata is truncated")
        calls.append(
            {
                "contract_address": to_hex(address),
                "selector": to_hex(selector),
                "calldata": [to_hex(value) for value in words[cursor:end]],
            }
        )
        cursor = end

    if cursor != len(words):
        raise InputError(
            f"import line has {len(words) - cursor} trailing value(s) after "
            f"{expected_calls} call(s)"
        )
    return calls


def command_encode(path: str) -> None:
    try:
        document = json.loads(read_text(path))
    except json.JSONDecodeError as exc:
        raise InputError(f"invalid JSON: {exc}") from exc
    calls = normalize_calls(document)
    encoded = encode_calls(calls)
    if decode_line(encoded) != [
        {
            "contract_address": to_hex(call["contract_address"]),
            "selector": to_hex(call["selector"]),
            "calldata": [to_hex(value) for value in call["calldata"]],
        }
        for call in calls
    ]:
        raise RuntimeError("internal round-trip validation failed")
    print(encoded)


def command_decode(path: str) -> None:
    print(json.dumps(decode_line(read_text(path)), indent=2))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Serialize Starknet Governor calls for the interface Import action."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    encode_parser = subparsers.add_parser("encode", help="encode calls JSON")
    encode_parser.add_argument("path", help="JSON path, or - for stdin")

    decode_parser = subparsers.add_parser("decode", help="decode and validate an import line")
    decode_parser.add_argument("path", help="text path, or - for stdin")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.command == "encode":
            command_encode(args.path)
        else:
            command_decode(args.path)
    except (InputError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
