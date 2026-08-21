#!/usr/bin/env bash
#
# Deterministic-render diff harness.
#
# Renders the AWS terraform + ansible set into <out_dir> with every random input
# pinned, so two renders of the SAME revision are byte-identical and any diff
# between two revisions is a real output change.
#
# Two-revision recipe:
#
#   git checkout <commit-A> && bash bin/render_harness.sh /tmp/base
#   git checkout <commit-B> && bash bin/render_harness.sh /tmp/head
#   diff -r /tmp/base /tmp/head    # empty == no AWS output change
#
# The operator (or CI) supplies the two commits; this script renders one.
set -euo pipefail

OUT_DIR="${1:?usage: render_harness.sh <out_dir>}"

PINNED_PEM_APP_NAME="render-harness-pinned"
PINNED_DB_PASSWORD="RenderHarnessPinnedPassword"

# Never rm -rf the caller's argument. An earlier version did, behind a guard that only
# rejected relative paths and directories containing .git/mix.exs — so `/`, `$HOME`, `/opt`
# and any other absolute path all sailed through it. Instead, refuse to touch anything that
# already exists and delete only the two subdirectories this script creates itself.
case "$OUT_DIR" in
  /*) ;;
  *) echo "render_harness.sh: <out_dir> must be an absolute path, got '$OUT_DIR'" >&2; exit 2 ;;
esac

if [ -e "$OUT_DIR" ] && [ ! -d "$OUT_DIR/terraform" ] && [ ! -d "$OUT_DIR/ansible" ]; then
  echo "render_harness.sh: '$OUT_DIR' already exists and is not a previous render dir." >&2
  echo "  Refusing to touch it. Pass a fresh path." >&2
  exit 2
fi

mkdir -p "$OUT_DIR"
rm -rf "${OUT_DIR:?}/terraform" "${OUT_DIR:?}/ansible"

mix terraform.build \
  --render-dir "$OUT_DIR/terraform" \
  --pem-app-name "$PINNED_PEM_APP_NAME" \
  --db-password "$PINNED_DB_PASSWORD" \
  --quiet < /dev/null

mix ansible.build --render-dir "$OUT_DIR/ansible" --quiet < /dev/null
