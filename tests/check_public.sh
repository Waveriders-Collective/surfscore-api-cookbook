#!/usr/bin/env bash
# Check that nothing private is about to be published from this public repo.
#
# Usage:   ./tests/check_public.sh                    # tracked files + unpushed commit messages
#          ./tests/check_public.sh --commit-msg FILE  # one message (use as a commit-msg hook)
#
# Optional hooks:
#   ln -sf ../../tests/check_public.sh .git/hooks/pre-commit
#   printf '#!/bin/sh\nexec tests/check_public.sh --commit-msg "$1"\n' > .git/hooks/commit-msg && chmod +x .git/hooks/commit-msg
#
# Flags secrets, ids (UUIDs, H3 cells), AI attribution, references to private
# repositories or issues, and every term in .public-denylist (gitignored: one org,
# customer or partner name per line, kept local so the list itself is never published).
# Prints where and why, never the matched text. Exit 1 if anything is found.
set -euo pipefail
cd "$(dirname "$0")/.."

msg_file=""
if [ "${1:-}" = "--commit-msg" ]; then msg_file="${2:?--commit-msg needs a file}"; fi

python3 -I - "$msg_file" <<'PY'
import os, re, subprocess, sys

msg_file = sys.argv[1]
RULES = [
    ("API key", re.compile(r"ss_live_[A-Za-z0-9_-]{20,}")),
    ("webhook secret", re.compile(r"whsec_[A-Za-z0-9_-]{20,}")),
    ("UUID (session/map/org id?)", re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", re.I)),
    ("H3 cell id", re.compile(r"\b8[0-9a-f]{14}\b")),
    ("AI attribution", re.compile(r"co-authored-by|claude-session|generated with \[?claude|claude\.ai/code|noreply@anthropic\.com", re.I)),
    ("private repo reference", re.compile(r"Waveriders-Collective/(?!surfscore-api-cookbook\b)[A-Za-z0-9_.-]+")),
    ("issue/PR reference to another repo", re.compile(r"\b[A-Za-z][A-Za-z0-9_.-]*#[0-9]+\b")),
]
deny = []
if os.path.exists(".public-denylist"):
    for line in open(".public-denylist", encoding="utf-8"):
        term = line.strip()
        if term and not term.startswith("#"):
            deny.append(re.compile(re.escape(term), re.I))

SKIP_PREFIXES = ("openapi/", "LICENSE")   # published spec and licence text
SELF = "tests/check_public.sh"            # holds the patterns themselves

def check(label, text):
    found = 0
    for n, line in enumerate(text.splitlines(), 1):
        for name, rx in RULES:
            if rx.search(line):
                print(f"  {label}:{n}: {name}"); found += 1
        if any(rx.search(line) for rx in deny):
            print(f"  {label}:{n}: denylisted name"); found += 1
    return found

total = 0
if msg_file:
    total += check("commit message", open(msg_file, encoding="utf-8").read())
else:
    files = subprocess.run(["git", "ls-files", "-c", "-o", "--exclude-standard"],
                           capture_output=True, text=True, check=True).stdout.split()
    for f in files:
        if f.startswith(SKIP_PREFIXES) or f == SELF or not os.path.isfile(f):
            continue
        try:
            total += check(f, open(f, encoding="utf-8").read())
        except UnicodeDecodeError:
            continue
    base = subprocess.run(["git", "rev-parse", "--verify", "-q", "origin/main"],
                          capture_output=True, text=True).stdout.strip()
    rng = [f"{base}..HEAD"] if base else ["HEAD"]
    log = subprocess.run(["git", "log", "--format=%H%n%an <%ae>%n%cn <%ce>%n%B%x00", *rng],
                         capture_output=True, text=True).stdout
    for entry in filter(str.strip, log.split("\0")):
        sha = entry.strip().split("\n", 1)[0][:7]
        total += check(f"commit {sha}", entry.strip().split("\n", 1)[1] if "\n" in entry.strip() else "")

if total:
    print(f"check_public: {total} problem(s). Fix them before committing or pushing.")
    sys.exit(1)
print("check_public: clean")
PY
