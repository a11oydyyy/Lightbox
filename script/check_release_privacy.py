#!/usr/bin/env python3
"""Fail closed before publishing Git metadata or macOS release artifacts."""
import pathlib
import re
import subprocess
import sys
import zipfile


def git(*args):
    return subprocess.check_output(["git", *args]).decode().strip()


def check_email(email, label):
    if email != "noreply@github.com" and not re.fullmatch(r"[^\s@]+@(?:users\.)?noreply\.github\.com", email):
        raise ValueError(f"{label}: 必須使用 GitHub noreply 郵箱（不顯示原值）。")


def check_commit(commit):
    for role, field in (("author", "%ae"), ("committer", "%ce")):
        check_email(git("show", "-s", f"--format={field}", commit), f"{commit[:12]} {role}")


def check_ref(ref):
    obj = git("rev-parse", ref)
    # Annotated tags have a separate identity, including nested tags.
    while git("cat-file", "-t", obj) == "tag":
        header = git("cat-file", "-p", obj).split("\n\n", 1)[0]
        match = re.search(r"^tagger .* <([^>]+)>", header, re.M)
        if not match:
            raise ValueError("標籤缺少 tagger 身份。")
        check_email(match[1], f"tag {obj[:12]}")
        obj = re.search(r"^object ([0-9a-f]+)$", header, re.M)[1]
    # Check the full reachable history, not only the last commit. This prevents
    # an old local clone from reintroducing the pre-cleanup public history.
    for commit in git("rev-list", obj).splitlines():
        check_commit(commit)


def check_bytes(data, label):
    if re.search(rb"/(?:Users|home)/[^/\s\x00]+/", data):
        raise ValueError(f"{label}: 含本機使用者路徑（不顯示原值）。")
    if re.search(rb"[A-Za-z0-9._%+\-]+@(?:gmail|googlemail|outlook|hotmail|live|icloud|me|yahoo|qq|163|126)\.(?:com|net)\b", data, re.I):
        raise ValueError(f"{label}: 含個人郵箱（不顯示原值）。")


def main():
    mode = sys.argv[1]
    if mode == "identity":
        for role in ("AUTHOR", "COMMITTER"):
            identity = git("var", f"GIT_{role}_IDENT")
            check_email(re.search(r"<([^>]+)>", identity)[1], role)
        check_ref("HEAD")
    elif mode == "refs":
        for ref in sys.argv[2:]:
            check_ref(ref)
    elif mode == "pre-push":
        for line in sys.stdin:
            _, local_sha, _, _ = line.split()
            if set(local_sha) != {"0"}:
                check_ref(local_sha)
    elif mode == "bundle":
        root = pathlib.Path(sys.argv[2])
        if not root.is_dir():
            raise ValueError("找不到 App bundle。")
        for file in root.rglob("*"):
            if file.is_file():
                check_bytes(file.read_bytes(), str(file.relative_to(root)))
    elif mode == "archive":
        with zipfile.ZipFile(sys.argv[2]) as archive:
            for member in archive.infolist():
                check_bytes(archive.read(member), member.filename)
    else:
        raise ValueError("未知的隱私檢查模式。")
    print("隱私檢查通過。")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as error:
        print(f"隱私檢查未通過：{error}", file=sys.stderr)
        sys.exit(1)
