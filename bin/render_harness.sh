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

rm -rf "$OUT_DIR"

mix terraform.build \
  --render-dir "$OUT_DIR/terraform" \
  --pem-app-name "$PINNED_PEM_APP_NAME" \
  --db-password "$PINNED_DB_PASSWORD" \
  --quiet < /dev/null

mix ansible.build --render-dir "$OUT_DIR/ansible" --quiet < /dev/null
