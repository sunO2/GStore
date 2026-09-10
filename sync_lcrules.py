#!/usr/bin/env python3
"""同步 LibChecker 规则库到 assets/lcrules/*.json。

数据源: 本地克隆的 LibChecker-Rules-Bundle 仓库
  library/src/main/assets/lcrules/rules.db (SQLite) + version.prop

目标: GStore assets/lcrules/ 下的 JSON 快照(与 apk_library_analyzer.dart 的加载格式一致)
  - rules_native.json     type=0
  - rules_dex.json        type=5
  - rules_component.json  type=1/2/3/4
  - rules_static.json     type=6  (STATIC)
  - rules_package.json    type=9  (PACKAGE)
  - version.txt           规则版本号

用法:
  python3 sync_lcrules.py [/path/to/LibChecker-Rules-Bundle]

依赖: python3(仅标准库 sqlite3/json)。
注意: 需先克隆规则仓库:
  git clone git@github.com:LibChecker/LibChecker-Rules-Bundle.git
"""
import json
import os
import sqlite3
import sys

# 规则 type 分类(仅导出 GStore 已消费 + 计划接入的类型;其余忽略)
OUTPUTS = {
    "rules_native.json": 0,
    "rules_component.json": (1, 2, 3, 4),
    "rules_dex.json": 5,
    "rules_static.json": 6,
    "rules_package.json": 9,
}

DEFAULT_BUNDLE = (
    os.path.expanduser("~/develop/flutter/project/github/LibChecker-Rules-Bundle")
)
DEFAULT_OUT = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "assets", "lcrules"
)


def _row_to_rule(row):
    """db 行 → JSON 规则(与 NativeLibraryRule.toJson 字段一致: name/label/type/isRegexRule 0/1)"""
    _, name, label, type_, _, is_regex, _ = row  # _id, name, label, type, iconIndex, isRegexRule, regexName
    return {
        "name": name,
        "label": label,
        "type": type_,
        "isRegexRule": int(is_regex),
    }


def main():
    bundle = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_BUNDLE
    db_path = os.path.join(bundle, "library/src/main/assets/lcrules/rules.db")
    version_path = os.path.join(bundle, "library/src/main/assets/lcrules/version.prop")
    out_dir = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_OUT

    if not os.path.exists(db_path):
        print(f"[错误] 未找到规则库: {db_path}")
        print("请先克隆: git clone git@github.com:LibChecker/LibChecker-Rules-Bundle.git")
        sys.exit(1)

    # 版本
    version = "unknown"
    if os.path.exists(version_path):
        with open(version_path) as f:
            for line in f:
                if line.startswith("version="):
                    version = line.strip().split("=", 1)[1]
                    break

    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        rows = conn.execute(
            "SELECT _id,name,label,type,iconIndex,isRegexRule,regexName FROM rules_table ORDER BY _id"
        ).fetchall()
    finally:
        conn.close()

    print(f"规则库 v{version}, 共 {len(rows)} 条")
    os.makedirs(out_dir, exist_ok=True)

    for filename, type_sel in OUTPUTS.items():
        wanted = type_sel if isinstance(type_sel, tuple) else (type_sel,)
        items = [_row_to_rule(r) for r in rows if r[3] in wanted]
        path = os.path.join(out_dir, filename)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(items, f, ensure_ascii=False, indent=None)  # 紧凑单行,与现状一致
        print(f"  {filename}: {len(items)} 条 → {path}")

    # 版本标记
    with open(os.path.join(out_dir, "version.txt"), "w", encoding="utf-8") as f:
        f.write(f"v{version}\n")
    print(f"  版本标记: v{version} → {out_dir}/version.txt")
    print("完成。请用 dart analyze + flutter test 验证后提交。")


if __name__ == "__main__":
    main()