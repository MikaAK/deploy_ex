#!/usr/bin/env bash
# Usage: update_release_state.sh <bucket> <release_state_prefix> <app_name> <s3_object_key>
#
# Tracks which release is deployed by maintaining two files in S3:
#   <release_state_prefix>/<app_name>/current_release.txt
#   <release_state_prefix>/<app_name>/release_history.txt
#
# If the current release matches s3_object_key, prints "unchanged" and exits.
# Otherwise updates both files and prints "changed".

set -euo pipefail

BUCKET="$1"
STATE_PREFIX="$2"
APP_NAME="$3"
S3_KEY="$4"

CURRENT_KEY="${STATE_PREFIX}/${APP_NAME}/current_release.txt"
HISTORY_KEY="${STATE_PREFIX}/${APP_NAME}/release_history.txt"

CURRENT_FILE="/tmp/${APP_NAME}_current_release.txt"
HISTORY_FILE="/tmp/${APP_NAME}_release_history.txt"

# Fetch current release (may not exist yet)
existing=""
if aws s3 cp "s3://${BUCKET}/${CURRENT_KEY}" "$CURRENT_FILE" 2>/dev/null; then
  existing=$(cat "$CURRENT_FILE" | tr -d '[:space:]')
fi

# Skip if unchanged
if [ "$existing" = "$S3_KEY" ]; then
  echo "unchanged"
  exit 0
fi

# Fetch or create history
if ! aws s3 cp "s3://${BUCKET}/${HISTORY_KEY}" "$HISTORY_FILE" 2>/dev/null; then
  touch "$HISTORY_FILE"
fi

# Append old release to history (if there was one)
if [ -n "$existing" ]; then
  echo "$existing" >> "$HISTORY_FILE"
fi

# Write new current release
echo "$S3_KEY" > "$CURRENT_FILE"

# Upload both
aws s3 cp "$CURRENT_FILE" "s3://${BUCKET}/${CURRENT_KEY}" --quiet
aws s3 cp "$HISTORY_FILE" "s3://${BUCKET}/${HISTORY_KEY}" --quiet

echo "changed"
