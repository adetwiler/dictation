#!/usr/bin/env bash
#
# release-check.sh: the WHOLE TREE version of the pre-commit gates, plus the
# tests. Run it before pushing anything you would be embarrassed to publish.
#
# The pre-commit hook only sees STAGED ADDITIONS, which is right for a commit
# gate (an untouched line elsewhere must not block unrelated work) and wrong for
# a release gate. This one reads every tracked file, so it catches anything that
# landed before the hook was installed. That is not hypothetical here: this repo
# was a private personal tool for weeks before it was made public.
#
#   bash scripts/release-check.sh
#
# Exit 0 means clean. Anything else means do not push.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
fail=0
say_fail() { echo "FAIL: $*"; fail=1; }
say_ok()   { echo "ok:   $*"; }

# --- 1. Leak audit, whole tree ------------------------------------------------
# The denylist is machine-local and gitignored, because a list of the things
# that must never leak is itself a thing that must never leak. Without it this
# check cannot run, and it says so rather than passing silently: a leak gate
# that quietly no-ops is worse than none, because you stop looking.
DENY=".githooks/denylist.local"
if [ ! -f "$DENY" ]; then
  say_fail "no $DENY. Copy .githooks/denylist.example and fill it in."
else
  pattern="$(grep -vE '^\s*#|^\s*$' "$DENY" | paste -sd '|' -)"
  if [ -z "$pattern" ]; then
    say_fail "$DENY has no terms in it."
  else
    hits="$(git ls-files -z | xargs -0 grep -InE "$pattern" 2>/dev/null || true)"
    if [ -n "$hits" ]; then
      echo "FAIL: tracked files contain a private tell:"
      echo "$hits" | head -40
      fail=1
    else
      say_ok "leak audit clean ($(grep -cvE '^\s*#|^\s*$' "$DENY") terms over $(git ls-files | wc -l | tr -d ' ') files)"
    fi
  fi
fi

# --- 2. Whole-tree dash scan --------------------------------------------------
# Byte escapes so this file never contains the characters it bans.
EM=$(printf '\xe2\x80\x94'); EN=$(printf '\xe2\x80\x93')
dashes="$(git ls-files -z | xargs -0 grep -InE "$EM|$EN" 2>/dev/null || true)"
if [ -n "$dashes" ]; then
  echo "FAIL: tracked files contain an em dash or en dash:"
  echo "$dashes" | head -20
  fail=1
else
  say_ok "no em dashes or en dashes"
fi

# --- 3. Dead relative markdown links -----------------------------------------
# A public README that links to a file nobody shipped is the first thing a
# stranger hits and the cheapest thing to get wrong.
dead=0
while IFS= read -r md; do
  while IFS= read -r link; do
    [ -z "$link" ] && continue
    case "$link" in http*|\#*|mailto:*) continue ;; esac
    target="${link%%#*}"
    [ -z "$target" ] && continue
    if [ ! -e "$(dirname "$md")/$target" ]; then
      echo "FAIL: $md links to missing $target"
      dead=1
    fi
  done < <(grep -oE '\]\([^)]+\)' "$md" 2>/dev/null | sed 's/^](//; s/)$//')
done < <(git ls-files '*.md')
if [ "$dead" -ne 0 ]; then fail=1; else say_ok "no dead relative markdown links"; fi

# --- 4. The tests actually pass ----------------------------------------------
# test.sh is unattended and always runs. test-delivery.sh opens a real window
# and takes focus, so it is opt-in: RUN_DELIVERY=1 bash scripts/release-check.sh
if ./test.sh >/dev/null 2>&1; then
  say_ok "test.sh passes"
else
  say_fail "test.sh FAILS. Run ./test.sh to see it."
fi
if [ "${RUN_DELIVERY:-0}" = "1" ]; then
  if ./test-delivery.sh >/dev/null 2>&1; then
    say_ok "test-delivery.sh passes"
  else
    say_fail "test-delivery.sh FAILS. Run ./test-delivery.sh to see it."
  fi
else
  echo "SKIP: test-delivery.sh (interactive, steals focus). RUN_DELIVERY=1 to include it."
fi

# --- 5. It still builds -------------------------------------------------------
if swiftc -O -target arm64-apple-macos26.0 -o /dev/null main.swift \
     -framework Cocoa -framework AVFoundation -framework Speech \
     -framework ServiceManagement -framework CoreAudio -framework AudioToolbox 2>/dev/null; then
  say_ok "main.swift compiles"
else
  say_fail "main.swift DOES NOT COMPILE."
fi

echo ""
if [ "$fail" -ne 0 ]; then echo "RELEASE CHECK FAILED. Do not push."; exit 1; fi
echo "RELEASE CHECK PASSED."
