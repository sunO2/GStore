#!/usr/bin/env python3
"""Generate the deterministic legacy-download fixture used by `parity.sh --download`.

The fixture has two SQLite databases and one file tree:

  legacy/download_task.db  Floor-like table with camelCase columns
  module/download.db       download-module v4 table with snake_case columns
  files/                   `.part{i}`, `.temp`, `.merge`, final files

Both the Rust harness and the Dart dump read these bytes and must produce the
same canonical document. The generator is intentionally strict: it fails if a
status is missing, a dedup duplicate is absent, or a fixture file has the wrong
size, so a broken fixture can never masquerade as a passing parity run.
"""

from __future__ import annotations

import argparse
import json
import shutil
import sqlite3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUT = ROOT / "target" / "spike-evidence" / "download-parity"

FLOOR_DDL = """
CREATE TABLE download_task (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    appId               TEXT NOT NULL,
    appName             TEXT NOT NULL,
    version             TEXT NOT NULL,
    fileName            TEXT NOT NULL,
    url                 TEXT NOT NULL,
    filePath            TEXT NOT NULL,
    total               INTEGER NOT NULL,
    received            INTEGER NOT NULL,
    status              INTEGER NOT NULL,
    speedBps            INTEGER NOT NULL,
    etaSec              INTEGER,
    error               TEXT,
    segments            TEXT,
    createdAt           INTEGER NOT NULL,
    updatedAt           INTEGER NOT NULL,
    dedupKey            TEXT,
    installAfterDownload INTEGER NOT NULL DEFAULT 0,
    lastStartedAt       INTEGER,
    saveFileName        TEXT
);
CREATE TABLE parity_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
"""

MODULE_DDL = """
CREATE TABLE download_task (
    id                     INTEGER PRIMARY KEY AUTOINCREMENT,
    app_id                 TEXT NOT NULL,
    app_name               TEXT NOT NULL,
    version                TEXT NOT NULL,
    file_name              TEXT NOT NULL,
    url                    TEXT NOT NULL,
    file_path              TEXT NOT NULL,
    total                  INTEGER NOT NULL DEFAULT 0,
    received               INTEGER NOT NULL DEFAULT 0,
    status                 INTEGER NOT NULL,
    speed_bps              INTEGER NOT NULL DEFAULT 0,
    eta_sec                INTEGER,
    error                  TEXT,
    fail_kind              TEXT,
    retries                INTEGER NOT NULL DEFAULT 0,
    server_meta            TEXT,
    expected_sha256        TEXT,
    actual_sha256          TEXT,
    priority               INTEGER NOT NULL DEFAULT 0,
    queue_reason           TEXT,
    created_at             INTEGER NOT NULL,
    updated_at             INTEGER NOT NULL,
    dedup_key              TEXT NOT NULL DEFAULT '',
    kind                   TEXT NOT NULL DEFAULT 'file',
    resource_id            TEXT NOT NULL DEFAULT '',
    resource_version       TEXT NOT NULL DEFAULT '',
    install_after_download INTEGER NOT NULL DEFAULT 0,
    last_started_at        INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE download_segment (
    task_id    INTEGER NOT NULL,
    idx        INTEGER NOT NULL,
    start_byte INTEGER NOT NULL,
    end_byte   INTEGER NOT NULL,
    received   INTEGER NOT NULL DEFAULT 0,
    done       INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (task_id, idx)
);
"""

BASE_MS = 1_700_000_000_000


def resolve_save_path(downloads_dir: str, docs_dir: str, save: str | None, file_name: str) -> str:
    if save and save.startswith("/"):
        return save
    return f"{downloads_dir}/{file_name}"


def write_bytes(path: Path, size: int, fill: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(bytes([fill]) * size)


def floor_rows(files_dir: Path, downloads_dir: str, docs_dir: str) -> list[dict]:
    def row(**overrides: object) -> dict:
        base = {
            "appId": "com.example.app",
            "appName": "Example",
            "version": "1.0.0",
            "fileName": "app.bin",
            "url": "https://example.test/app.bin",
            "saveFileName": None,
            "total": 1000,
            "received": 0,
            "status": 0,
            "speedBps": 0,
            "etaSec": None,
            "error": None,
            "segments": None,
            "dedupKey": "app:default",
            "installAfterDownload": 0,
            "lastStartedAt": BASE_MS,
            "createdAt": BASE_MS,
            "updatedAt": BASE_MS + 1000,
        }
        base.update(overrides)
        base["filePath"] = resolve_save_path(
            downloads_dir, docs_dir, base["saveFileName"], base["fileName"]
        )
        return base

    rows = [
        row(
            appId="com.example.queued",
            appName="Queued",
            version="1.0.0",
            fileName="queued.bin",
            url="https://example.test/queued.bin",
            total=1000,
            received=0,
            status=0,
            dedupKey="app:queued",
        ),
        row(
            appId="com.example.connecting",
            appName="Connecting",
            version="1.0.1",
            fileName="connecting.bin",
            url="https://example.test/connecting.bin",
            total=2000,
            received=100,
            status=1,
            dedupKey="app:connecting",
            etaSec=30,
        ),
        row(
            appId="com.example.downloading",
            appName="Downloading",
            version="1.0.2",
            fileName="nested/dir/downloading.bin",
            url="https://example.test/downloading.bin",
            total=3000,
            received=900,
            status=2,
            dedupKey="app:downloading",
            installAfterDownload=1,
        ),
        row(
            appId="com.example.paused",
            appName="Paused",
            version="1.0.3",
            fileName="paused.bin",
            url="https://example.test/paused.bin",
            total=4000,
            received=1000,
            status=3,
            dedupKey="app:paused",
            error="paused by user",
        ),
        row(
            appId="com.example.completed",
            appName="Completed",
            version="1.0.4",
            fileName="completed.bin",
            url="https://example.test/completed.bin",
            total=2048,
            received=2048,
            status=4,
            dedupKey="app:completed",
            installAfterDownload=1,
        ),
        row(
            appId="com.example.failed",
            appName="Failed",
            version="1.0.5",
            fileName="failed.bin",
            url="https://example.test/failed.bin",
            total=5000,
            received=2500,
            status=5,
            dedupKey="app:failed",
            error="network reset",
        ),
        row(
            appId="com.example.cancelled",
            appName="Cancelled",
            version="1.0.6",
            fileName="cancelled.bin",
            url="https://example.test/cancelled.bin",
            total=6000,
            received=1000,
            status=6,
            dedupKey="app:cancelled",
        ),
        row(
            appId="com.example.unknown",
            appName="UnknownStatus",
            version="1.0.7",
            fileName="unknown.bin",
            url="https://example.test/unknown.bin",
            total=7000,
            received=700,
            status=9,
            dedupKey="app:unknown",
        ),
        # Duplicate dedup key: the first `app:paused` row already owns the core
        # row, so this row must be skipped (core row wins).
        row(
            appId="com.example.duplicate",
            appName="Duplicate",
            version="9.9.9",
            fileName="paused.bin",
            url="https://example.test/duplicate.bin",
            total=9999,
            received=1,
            status=0,
            dedupKey="app:paused",
        ),
        row(
            appId="com.example.absolute",
            appName="Absolute",
            version="2.0.0",
            fileName="server-name.bin",
            url="https://example.test/absolute.bin",
            saveFileName=str(files_dir / "absolute.bin"),
            total=1200,
            received=200,
            status=2,
            dedupKey="app:absolute",
        ),
        row(
            appId="com.example.relative",
            appName="Relative",
            version="2.0.1",
            fileName="fallback.bin",
            url="https://example.test/relative.bin",
            saveFileName="relative/name.bin",
            total=800,
            received=0,
            status=0,
            dedupKey="app:relative",
        ),
        row(
            appId="com.example.rustmerge",
            appName="RustMerge",
            version="2.0.2",
            fileName="rust-merge.bin",
            url="https://example.test/rust-merge.bin",
            total=900,
            received=300,
            status=2,
            dedupKey="app:rustmerge",
        ),
        row(
            appId="com.example.stray",
            appName="StrayPart",
            version="2.0.3",
            fileName="stray.bin",
            url="https://example.test/stray.bin",
            total=500,
            received=50,
            status=3,
            dedupKey="app:stray",
        ),
        # No dedupKey: both sides must derive `legacy:<url>|<filePath>`.
        row(
            appId="com.example.nodedup",
            appName="NoDedup",
            version="2.0.4",
            fileName="no-dedup.bin",
            url="https://example.test/no-dedup.bin",
            total=1100,
            received=50,
            status=1,
            dedupKey=None,
        ),
    ]
    return rows


def module_rows(downloads_dir: str) -> tuple[list[dict], list[tuple]]:
    def row(**overrides: object) -> dict:
        base = {
            "id": 100,
            "app_id": "com.example.module",
            "app_name": "Module",
            "version": "1.0.0",
            "file_name": "module.bin",
            "url": "https://example.test/module.bin",
            "file_path": f"{downloads_dir}/module.bin",
            "total": 100,
            "received": 0,
            "status": 0,
            "description": "",
            "speed_bps": 0,
            "eta_sec": None,
            "error": None,
            "fail_kind": None,
            "retries": 0,
            "server_meta": None,
            "expected_sha256": None,
            "actual_sha256": None,
            "priority": 0,
            "queue_reason": None,
            "created_at": BASE_MS,
            "updated_at": BASE_MS + 1000,
            "dedup_key": "module:default",
            "kind": "app",
            "resource_id": "com.example.module",
            "resource_version": "1.0.0",
            "install_after_download": 0,
            "last_started_at": BASE_MS,
        }
        base.update(overrides)
        return base

    rows = [
        # Matches the Floor paused row: core metadata must win; the module only
        # links its module task id and segments.
        row(
            id=101,
            app_id="com.example.module-ignored",
            app_name="Module Paused (ignored)",
            version="9.9.9",
            file_name="paused.bin",
            url="https://example.test/paused.bin",
            file_path=f"{downloads_dir}/paused.bin",
            total=4000,
            received=1000,
            status=2,
            dedup_key="app:paused",
            expected_sha256="sha:paused",
            resource_id="com.example.module-ignored",
            resource_version="9.9.9",
        ),
        # Module-only row: inserted into the core table.
        row(
            id=102,
            app_id="com.example.moduleonly",
            app_name="Module Only",
            version="3.0.0",
            file_name="module-only.bin",
            url="https://example.test/module-only.bin",
            file_path=f"{downloads_dir}/module-only.bin",
            total=128,
            received=128,
            status=4,
            dedup_key="module:only",
            expected_sha256="sha:module",
            resource_id="com.example.moduleonly",
            resource_version="3.0.0",
            install_after_download=1,
        ),
        # Matches the Floor completed row.
        row(
            id=103,
            app_id="com.example.module-ignored",
            file_name="completed.bin",
            url="https://example.test/completed.bin",
            file_path=f"{downloads_dir}/completed.bin",
            total=2048,
            received=2048,
            status=4,
            dedup_key="app:completed",
            expected_sha256="sha:completed",
        ),
    ]
    segments = [
        (101, 0, 0, 399, 400, 1),
        (101, 1, 400, 3999, 600, 0),
    ]
    return rows, segments


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default=str(DEFAULT_OUT), help="fixture output directory")
    args = parser.parse_args()

    out = Path(args.out).resolve()
    if out.exists():
        shutil.rmtree(out)
    files_dir = out / "files"
    legacy_dir = out / "legacy"
    module_dir = out / "module"
    for directory in (files_dir, legacy_dir, module_dir):
        directory.mkdir(parents=True, exist_ok=True)
    downloads_dir = str(files_dir)
    docs_dir = str(files_dir / "docs")
    Path(docs_dir).mkdir(parents=True, exist_ok=True)

    floor = floor_rows(files_dir, downloads_dir, docs_dir)
    statuses = {row["status"] for row in floor}
    required = {0, 1, 2, 3, 4, 5, 6, 9}
    if not required.issubset(statuses):
        raise SystemExit(f"fixture statuses {sorted(statuses)} miss {sorted(required - statuses)}")
    dedups = [row["dedupKey"] for row in floor if row["dedupKey"]]
    if "app:paused" not in dedups or dedups.count("app:paused") < 2:
        raise SystemExit("fixture must contain a duplicate app:paused dedup key")

    legacy_db = legacy_dir / "download_task.db"
    connection = sqlite3.connect(legacy_db)
    try:
        connection.executescript(FLOOR_DDL)
        connection.executemany(
            """
            INSERT INTO download_task
                (appId, appName, version, fileName, url, filePath, total, received,
                 status, speedBps, etaSec, error, segments, createdAt, updatedAt,
                 dedupKey, installAfterDownload, lastStartedAt, saveFileName)
            VALUES (:appId, :appName, :version, :fileName, :url, :filePath, :total,
                    :received, :status, :speedBps, :etaSec, :error, :segments,
                    :createdAt, :updatedAt, :dedupKey, :installAfterDownload,
                    :lastStartedAt, :saveFileName)
            """,
            floor,
        )
        connection.executemany(
            "INSERT INTO parity_meta(key, value) VALUES (?, ?)",
            [
                ("downloads_dir", downloads_dir),
                ("docs_dir", docs_dir),
                ("files_dir", str(files_dir)),
            ],
        )
        connection.commit()
        integrity = connection.execute("PRAGMA integrity_check").fetchone()
        if integrity is None or integrity[0] != "ok":
            raise SystemExit(f"legacy fixture integrity_check failed: {integrity}")
    finally:
        connection.close()

    module_db = module_dir / "download.db"
    rows, segments = module_rows(downloads_dir)
    connection = sqlite3.connect(module_db)
    try:
        connection.executescript(MODULE_DDL)
        connection.executemany(
            """
            INSERT INTO download_task
                (id, app_id, app_name, version, file_name, url, file_path, total,
                 received, status, speed_bps, eta_sec, error, fail_kind, retries,
                 server_meta, expected_sha256, actual_sha256, priority, queue_reason,
                 created_at, updated_at, dedup_key, kind, resource_id,
                 resource_version, install_after_download, last_started_at)
            VALUES (:id, :app_id, :app_name, :version, :file_name, :url, :file_path,
                    :total, :received, :status, :speed_bps, :eta_sec, :error,
                    :fail_kind, :retries, :server_meta, :expected_sha256,
                    :actual_sha256, :priority, :queue_reason, :created_at,
                    :updated_at, :dedup_key, :kind, :resource_id,
                    :resource_version, :install_after_download, :last_started_at)
            """,
            rows,
        )
        connection.executemany(
            "INSERT INTO download_segment(task_id, idx, start_byte, end_byte, received, done)"
            " VALUES (?, ?, ?, ?, ?, ?)",
            segments,
        )
        connection.commit()
        integrity = connection.execute("PRAGMA integrity_check").fetchone()
        if integrity is None or integrity[0] != "ok":
            raise SystemExit(f"module fixture integrity_check failed: {integrity}")
    finally:
        connection.close()

    write_bytes(files_dir / "paused.bin.part0", 400, 0x61)
    write_bytes(files_dir / "paused.bin.part1", 600, 0x62)
    write_bytes(files_dir / "paused.bin.temp", 700, 0x63)
    write_bytes(files_dir / "rust-merge.bin.part0", 300, 0x64)
    write_bytes(files_dir / "rust-merge.bin.merge", 300, 0x65)
    write_bytes(files_dir / "stray.bin.part", 50, 0x66)
    write_bytes(files_dir / "completed.bin", 2048, 0x67)
    write_bytes(files_dir / "module-only.bin", 128, 0x68)

    expected_sizes = {
        "paused.bin.part0": 400,
        "paused.bin.part1": 600,
        "paused.bin.temp": 700,
        "rust-merge.bin.part0": 300,
        "rust-merge.bin.merge": 300,
        "stray.bin.part": 50,
        "completed.bin": 2048,
        "module-only.bin": 128,
    }
    for name, size in expected_sizes.items():
        actual = (files_dir / name).stat().st_size
        if actual != size:
            raise SystemExit(f"fixture file {name}: expected {size} bytes, got {actual}")

    meta = {
        "out": str(out),
        "legacy_db": str(legacy_db),
        "module_db": str(module_db),
        "files_dir": str(files_dir),
        "downloads_dir": downloads_dir,
        "docs_dir": docs_dir,
        "floor_rows": len(floor),
        "module_rows": len(rows),
    }
    (out / "meta.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(meta, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
