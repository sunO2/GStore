#!/usr/bin/env python3
"""Canonicalize and diff the Dart/Rust LocalDb parity JSON documents."""

from __future__ import annotations

import argparse
import difflib
import json
import sys
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dart", required=True, help="Dart parity JSON path")
    parser.add_argument("--rust", required=True, help="Rust parity JSON path")
    parser.add_argument(
        "--inject-field-diff",
        action="store_true",
        help="mutate getAllApps[0].name in the Rust document to prove the gate fails",
    )
    return parser.parse_args()


def normalize(node: Any) -> Any:
    if isinstance(node, dict):
        return {key: normalize(value) for key, value in sorted(node.items())}
    if isinstance(node, list):
        items = [normalize(value) for value in node]
        if items and all(isinstance(item, dict) and "appId" in item for item in items):
            items.sort(key=lambda item: item["appId"])
        return items
    return node


def render(document: Any) -> list[str]:
    return json.dumps(
        normalize(document), indent=2, sort_keys=True, ensure_ascii=False
    ).splitlines()


def main() -> int:
    args = parse_args()
    dart_doc = json.loads(Path(args.dart).read_text(encoding="utf-8"))
    rust_doc = json.loads(Path(args.rust).read_text(encoding="utf-8"))

    if args.inject_field_diff:
        apps = rust_doc.get("getAllApps")
        if not isinstance(apps, list) or not apps:
            print("cannot inject drift: Rust getAllApps is empty", file=sys.stderr)
            return 2
        apps[0]["name"] = f"{apps[0].get('name')} (drift)"
        print('injected drift: rust getAllApps[0].name += " (drift)"')

    dart_lines = render(dart_doc)
    rust_lines = render(rust_doc)
    if dart_lines == rust_lines:
        print(
            "parity OK: getAllApps={} searchApps={} getAppInfoMissing={}".format(
                len(dart_doc.get("getAllApps", [])),
                len(dart_doc.get("searchApps", [])),
                dart_doc.get("getAppInfoMissing"),
            )
        )
        return 0

    diff = difflib.unified_diff(
        dart_lines,
        rust_lines,
        fromfile="dart/parity-dart.json",
        tofile="rust/parity-rust.json",
        lineterm="",
    )
    print("\n".join(diff))
    return 1


if __name__ == "__main__":
    sys.exit(main())
