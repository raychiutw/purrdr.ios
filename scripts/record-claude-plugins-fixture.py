#!/usr/bin/env python3 -I
# 從這台 Mac 的 Claude Code 設定(唯讀)錄一份 plugin／skill／指令的檔案結構，給 slash 選單的發現測試用(#15)。
#
# 用法:
#   scripts/record-claude-plugins-fixture.py
#
# 輸出到 tests/PurrdrTestSupport/Fixtures/claude-plugins/home/(整個重建),結構與 ~/.claude 相同:
# - plugins/installed_plugins.json:原樣，路徑的家目錄換成 /Users/demo,專案路徑換成假名。
# - settings.json:只留 enabledPlugins。
# - 每個已安裝 plugin 的 installPath:`.claude-plugin/plugin.json` 原樣;所有 SKILL.md 與指令 .md
#   (跳過 node_modules)只留 frontmatter,內文換成一行「(內容略)」。
# - 使用者層 skills:只留公開來源的(cloudflare 系列等);作者自己寫的(apim-*、skill-creator-advanced…)不錄。
#
# 只讀 ~/.claude,不改動任何東西。錄完一定要 grep 確認沒有真實帳號、主機名、專案名(Fixtures/README.md)。
import json
import os
import re
import shutil
import sys

HOME = os.path.expanduser("~")
CLAUDE = os.path.join(HOME, ".claude")
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
OUT = os.path.join(ROOT, "tests/PurrdrTestSupport/Fixtures/claude-plugins/home")
DEMO_HOME = "/Users/demo"
# 作者自己寫、可能帶工作內容的使用者層 skill:不錄。
PRIVATE_USER_SKILL = re.compile(r"^(apim-|skill-creator-advanced$|synced$)")


def demo_path(path):
    return path.replace(HOME, DEMO_HOME)


def out_path(path):
    """主機上的絕對路徑 → fixture 裡相對 home 的路徑。"""
    assert path.startswith(HOME + "/"), path
    return os.path.join(OUT, os.path.relpath(path, HOME))


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def frontmatter_only(src):
    with open(src, encoding="utf-8", errors="replace") as f:
        lines = f.read().split("\n")
    if lines and lines[0].strip() == "---":
        for i in range(1, len(lines)):
            if lines[i].strip() == "---":
                return "\n".join(lines[: i + 1]) + "\n\n(內容略)\n"
    return "(內容略)\n"


def copy_markdown_tree(src_root):
    for dirpath, dirnames, filenames in os.walk(src_root):
        dirnames[:] = [d for d in dirnames if d not in ("node_modules", ".git")]
        for name in filenames:
            src = os.path.join(dirpath, name)
            rel = os.path.relpath(src, src_root)
            is_skill = name == "SKILL.md"
            is_command = name.endswith(".md") and ("commands" + os.sep) in (os.sep + rel)
            if is_skill or is_command:
                write(out_path(src), frontmatter_only(src))


def main():
    if os.path.exists(OUT):
        shutil.rmtree(OUT)
    with open(os.path.join(CLAUDE, "plugins/installed_plugins.json")) as f:
        installed = json.load(f)
    project_names = {}
    for key, entries in installed["plugins"].items():
        for entry in entries:
            install = entry["installPath"]
            manifest = os.path.join(install, ".claude-plugin/plugin.json")
            if os.path.exists(manifest):
                with open(manifest) as f:
                    write(out_path(manifest), f.read())
            copy_markdown_tree(install)
            entry["installPath"] = demo_path(install)
            if "projectPath" in entry:
                fake = project_names.setdefault(entry["projectPath"], f"{DEMO_HOME}/Projects/other-project-{len(project_names) + 1}")
                entry["projectPath"] = fake
    write(os.path.join(OUT, ".claude/plugins/installed_plugins.json"), json.dumps(installed, indent=2) + "\n")
    with open(os.path.join(CLAUDE, "settings.json")) as f:
        settings = json.load(f)
    write(os.path.join(OUT, ".claude/settings.json"), json.dumps({"enabledPlugins": settings.get("enabledPlugins", {})}, indent=2) + "\n")
    skills = os.path.join(CLAUDE, "skills")
    for name in sorted(os.listdir(skills)):
        src = os.path.join(skills, name, "SKILL.md")
        if not PRIVATE_USER_SKILL.match(name) and os.path.exists(src):
            write(out_path(src), frontmatter_only(src))
    print("寫入", OUT, file=sys.stderr)
    record_skill_listing()


def record_skill_listing():
    """最近一份含 skill_listing 的對話紀錄中，第一筆 isInitial 的 attachment 行(去掉私有 skill 與個人欄位)。"""
    projects = os.path.join(CLAUDE, "projects")
    candidates = []
    for dirpath, _, filenames in os.walk(projects):
        for name in filenames:
            if name.endswith(".jsonl") and "subagents" not in dirpath:
                path = os.path.join(dirpath, name)
                candidates.append((os.path.getmtime(path), path))
    for _, path in sorted(candidates, reverse=True):
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                if '"skill_listing"' not in line:
                    continue
                row = json.loads(line)
                attachment = row.get("attachment") or {}
                if attachment.get("type") != "skill_listing" or not attachment.get("isInitial"):
                    continue
                keep = [i for i, n in enumerate(attachment["names"]) if not PRIVATE_USER_SKILL.match(n)]
                names = [attachment["names"][i] for i in keep]
                attachment["names"] = names
                if "digests" in attachment:
                    attachment["digests"] = [attachment["digests"][i] for i in keep]
                attachment["skillCount"] = len(names)
                entries = re.split(r"\n(?=- )", attachment["content"])
                attachment["content"] = "\n".join(e for e in entries if not PRIVATE_USER_SKILL.match(e[2:].split(":", 1)[0]))
                row = {
                    "parentUuid": "00000000-0000-4000-8000-000000000100",
                    "isSidechain": False,
                    "attachment": attachment,
                    "type": "attachment",
                    "uuid": "00000000-0000-4000-8000-000000000101",
                    "timestamp": row.get("timestamp"),
                    "userType": "external",
                    "entrypoint": row.get("entrypoint"),
                    "cwd": DEMO_HOME + "/Projects/ledger",
                    "sessionId": "00000000-0000-0000-0000-000000000001",
                    "version": row.get("version"),
                    "gitBranch": "main",
                }
                out = os.path.join(ROOT, "tests/PurrdrTestSupport/Fixtures/claude-code/skill-listing.jsonl")
                write(out, json.dumps(row, ensure_ascii=False) + "\n")
                print("寫入", out, file=sys.stderr)
                return


main()
