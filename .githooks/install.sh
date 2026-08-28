#!/usr/bin/env bash
#
# install.sh: point this repo's git at the tracked hooks in .githooks/.
# Run once per clone: bash .githooks/install.sh
#
# It sets core.hooksPath so git runs .githooks/pre-commit on every commit. The
# hooks are committed to the repo (unlike .git/hooks/, which is not), so this is
# how a fresh clone opts in to the gates. See method/09-safety-nets.md.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

git config core.hooksPath .githooks
chmod +x .githooks/pre-commit

echo "Installed: git will run .githooks/pre-commit on every commit."
echo "The em-dash gate and the bleed gate are now active for this clone."
