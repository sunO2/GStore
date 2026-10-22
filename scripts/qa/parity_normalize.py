#!/usr/bin/env python3
"""Canonicalize and diff the Dart/Rust parity JSON documents.

Two suites share this normalizer:

* default (channel/catalog): the LocalDb/catalog document produced by
  `dump_dart_parity_test.dart` / `gstore_core_parity`.
* ``--download``: the legacy-download document produced by
  `dump_dart_download_parity_test.dart` / `gstore_core_parity --download`.

In download mode the merge temp is canonicalized by ROLE (`.temp` and `.merge`
both become ``merge_temp``) and `checksum_supported` is removed from the diff
and reported as an explicit intentional difference instead: Dart has no
checksum verification, Rust does.
"""

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
        "--download",
        action="store_true",
        help="normalize the legacy-download document instead of LocalDb/catalog",
    )
    parser.add_argument(
        "--inject-field-diff",
        action="store_true",
        help="mutate the Rust document to prove the gate fails "
        "(status+1 in --download mode, name drift otherwise)",
    )
    parser.add_argument(
        "--inject-path-diff",
        action="store_true",
        help="append '-drift' to the first Rust dest_path (--download only)",
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


def normalize_download(document: dict[str, Any]) -> dict[str, Any]:
    rows = document.get("rows")
    if isinstance(rows, list):
        for row in rows:
            if not isinstance(row, dict):
                continue
            role = row.get("merge_temp_role")
            if role in ("temp", "merge"):
                row["merge_temp_role"] = "merge_temp"
            row.pop("checksum_supported", None)
        rows.sort(
            key=lambda row: (
                str(row.get("dedup_key") or ""),
                str(row.get("dest_path") or ""),
            )
        )
    return document


def intentional_differences(
    dart_doc: dict[str, Any], rust_doc: dict[str, Any]
) -> list[str]:
    dart_checksum = {
        row.get("checksum_supported")
        for row in dart_doc.get("rows", [])
        if isinstance(row, dict)
    }
    rust_checksum = {
        row.get("checksum_supported")
        for row in rust_doc.get("rows", [])
        if isinstance(row, dict)
    }
    if dart_checksum - {False}:
        raise SystemExit(
            f"unexpected Dart checksum_supported values: {sorted(dart_checksum, key=str)}"
        )
    if rust_checksum - {True}:
        raise SystemExit(
            f"unexpected Rust checksum_supported values: {sorted(rust_checksum, key=str)}"
        )
    return [
        "checksum_supported: dart=false rust=true "
        "(Dart has no expected_sha256 verification; diff omitted)",
        "merge_temp naming: dart=<dest>.temp rust=<dest>.merge "
        "(canonicalized as role merge_temp)",
    ]


def first_difference(left: Any, right: Any, path: str = "$") -> tuple[str, Any, Any] | None:
    """Return the first path whose value differs (after normalization)."""
    if type(left) is not type(right):
        return path, left, right
    if isinstance(left, dict):
        for key in sorted(set(left) | set(right)):
            if key not in left:
                return f"{path}.{key}", "<missing>", right[key]
            if key not in right:
                return f"{path}.{key}", left[key], "<missing>"
            found = first_difference(left[key], right[key], f"{path}.{key}")
            if found is not None:
                return found
        return None
    if isinstance(left, list):
        if len(left) != len(right):
            return f"{path}.length", len(left), len(right)
        for index, (left_item, right_item) in enumerate(zip(left, right)):
            found = first_difference(left_item, right_item, f"{path}[{index}]")
            if found is not None:
                return found
        return None
    if left != right:
        return path, left, right
    return None


def render(document: Any) -> list[str]:
    return json.dumps(
        normalize(document), indent=2, sort_keys=True, ensure_ascii=False
    ).splitlines()


def main() -> int:
    args = parse_args()
    dart_doc = json.loads(Path(args.dart).read_text(encoding="utf-8"))
    rust_doc = json.loads(Path(args.rust).read_text(encoding="utf-8"))

    if args.inject_path_diff and not args.download:
        print("--inject-path-diff is only defined for --download", file=sys.stderr)
        return 2

    if args.inject_field_diff:
        if args.download:
            rows = rust_doc.get("rows")
            if not isinstance(rows, list) or not rows:
                print("cannot inject drift: Rust download rows are empty", file=sys.stderr)
                return 2
            rows[0]["status_code"] = int(rows[0].get("status_code", 0)) + 1
            print(
                "injected drift: rust rows[0].status_code += 1 "
                f"(now {rows[0]['status_code']})"
            )
        else:
            apps = rust_doc.get("getAllApps")
            if not isinstance(apps, list) or not apps:
                print("cannot inject drift: Rust getAllApps is empty", file=sys.stderr)
                return 2
            apps[0]["name"] = f"{apps[0].get('name')} (drift)"
            print('injected drift: rust getAllApps[0].name += " (drift)"')

    if args.inject_path_diff:
        rows = rust_doc.get("rows")
        if not isinstance(rows, list) or not rows:
            print("cannot inject drift: Rust download rows are empty", file=sys.stderr)
            return 2
        rows[0]["dest_path"] = f"{rows[0].get('dest_path')}-drift"
        print(f"injected drift: rust rows[0].dest_path += '-drift' (now {rows[0]['dest_path']})")

    differences: list[str] = []
    if args.download:
        differences = intentional_differences(dart_doc, rust_doc)
        dart_doc = normalize_download(dart_doc)
        rust_doc = normalize_download(rust_doc)

    dart_lines = render(dart_doc)
    rust_lines = render(rust_doc)
    if dart_lines == rust_lines:
        if args.download:
            print(
                "parity OK (download): rows={} migration={}".format(
                    len(dart_doc.get("rows", [])),
                    json.dumps(dart_doc.get("migration", {}), sort_keys=True),
                )
            )
            for difference in differences:
                print(f"intentional difference: {difference}")
        else:
            print(
                "parity OK: getAllApps={} searchApps={} getAppInfoMissing={}".format(
                    len(dart_doc.get("getAllApps", [])),
                    len(dart_doc.get("searchApps", [])),
                    dart_doc.get("getAppInfoMissing"),
                )
            )
        return 0

    difference = first_difference(normalize(dart_doc), normalize(rust_doc))
    if difference is not None:
        path, dart_value, rust_value = difference
        print(f"first differing field: {path}")
        print(f"  dart: {json.dumps(dart_value, ensure_ascii=False, sort_keys=True)}")
        print(f"  rust: {json.dumps(rust_value, ensure_ascii=False, sort_keys=True)}")
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
