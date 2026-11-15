"""String Catalog 與編譯器抽出的字串比對(由 scripts/strings.sh 呼叫，說明見該檔)。"""

import glob
import json
import os
import sys

TARGETS = ("PurrdrFeatures",)


def source_strings(derived):
    """回傳 {key: comment}:PurrdrFeatures 編譯時抽出的 Localizable 表。"""
    pattern = os.path.join(derived, "Build", "Intermediates.noindex", "**", "*.stringsdata")
    found = {}
    files = [f for f in glob.glob(pattern, recursive=True) if any(f"/{t}-" in f or f"/{t}." in f for t in TARGETS)]
    if not files:
        sys.exit(f"在 {derived} 找不到 .stringsdata:要以 SWIFT_EMIT_LOC_STRINGS=YES 建置 package")
    for path in files:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        for entry in data.get("tables", {}).get("Localizable", []):
            comment = entry.get("comment") or ""
            if entry["key"] not in found or (comment and not found[entry["key"]]):
                found[entry["key"]] = comment
    return found


def units(node):
    if not node:
        return []
    out = []
    if "stringUnit" in node:
        out.append(node["stringUnit"])
    for group in node.get("variations", {}).values():
        for variation in group.values():
            out.extend(units(variation))
    return out


def translated(entry):
    if entry.get("shouldTranslate") is False:
        return True
    found = units(entry.get("localizations", {}).get("zh-Hant"))
    return bool(found) and all(u.get("state") == "translated" and u.get("value") for u in found)


def main():
    mode, catalog_path, derived = sys.argv[1:4]
    in_source = source_strings(derived)
    if os.path.exists(catalog_path):
        with open(catalog_path, encoding="utf-8") as f:
            catalog = json.load(f)
    else:
        catalog = {"sourceLanguage": "en", "strings": {}, "version": "1.1"}
    strings = catalog["strings"]

    missing = sorted(k for k in in_source if k not in strings)
    unused = sorted(k for k in strings if k not in in_source)
    untranslated = sorted(k for k in in_source if k in strings and not translated(strings[k]))

    if mode == "check":
        for title, keys in (("缺少的 key", missing), ("沒有繁體中文", untranslated), ("程式碼已不用", unused)):
            for key in keys:
                print(f"{title}: {key!r}")
        if missing or untranslated or unused:
            print("String Catalog 與程式碼不同步：執行 scripts/strings.sh sync 後補上繁體中文", file=sys.stderr)
            sys.exit(1)
        print(f"String Catalog OK({len(in_source)} 個字串)")
        return

    for key in missing:
        entry = {"extractionState": "manual"}
        if in_source[key]:
            entry["comment"] = in_source[key]
        strings[key] = entry
        print(f"新增: {key!r}")
    for key in unused:
        del strings[key]
        print(f"移除: {key!r}")
    for entry in strings.values():
        entry["extractionState"] = "manual"
    catalog["strings"] = dict(sorted(strings.items()))
    with open(catalog_path, "w", encoding="utf-8") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2, separators=(",", " : "))
        f.write("\n")
    for key in untranslated + missing:
        print(f"待翻譯: {key!r}")


main()
