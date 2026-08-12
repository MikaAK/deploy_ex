#!/usr/bin/env bash
# Usage: update_oci_release_state.sh <bucket> <namespace> <release_state_prefix> <app_name> <object_key>
#
# OCI Object Storage equivalent of update_release_state.sh. Tracks which release is deployed
# by maintaining two objects in the SAME bucket as the releases themselves:
#   <release_state_prefix>/<app_name>/current_release.txt
#   <release_state_prefix>/<app_name>/release_history.txt
#
# If the current release matches object_key, prints "unchanged" and exits.
# Otherwise updates both files and prints "changed".

set -euo pipefail

BUCKET="$1"
NAMESPACE="$2"
STATE_PREFIX="$3"
APP_NAME="$4"
OBJECT_KEY="$5"

CURRENT_KEY="${STATE_PREFIX}/${APP_NAME}/current_release.txt"
HISTORY_KEY="${STATE_PREFIX}/${APP_NAME}/release_history.txt"

CURRENT_FILE="/tmp/${APP_NAME}_current_release.txt"
HISTORY_FILE="/tmp/${APP_NAME}_release_history.txt"

# Fetch current release (may not exist yet)
existing=""
if oci os object get --namespace "$NAMESPACE" --bucket-name "$BUCKET" --name "$CURRENT_KEY" --file "$CURRENT_FILE" 2>/dev/null; then
  existing=$(tr -d '[:space:]' < "$CURRENT_FILE")
fi

# Skip if unchanged
if [ "$existing" = "$OBJECT_KEY" ]; then
  echo "unchanged"
  exit 0
fi

# Fetch or create history
if ! oci os object get --namespace "$NAMESPACE" --bucket-name "$BUCKET" --name "$HISTORY_KEY" --file "$HISTORY_FILE" 2>/dev/null; then
  touch "$HISTORY_FILE"
fi

# Append old release to history (if there was one)
if [ -n "$existing" ]; then
  echo "$existing" >> "$HISTORY_FILE"
fi

# Write new current release
echo "$OBJECT_KEY" > "$CURRENT_FILE"

# Upload both (the oci CLI prints the object's etag/metadata as JSON on success — matches
# the AWS script's `--quiet` intent by discarding it, keeping stdout to just the final line)
oci os object put --namespace "$NAMESPACE" --bucket-name "$BUCKET" --name "$CURRENT_KEY" --file "$CURRENT_FILE" --force > /dev/null
oci os object put --namespace "$NAMESPACE" --bucket-name "$BUCKET" --name "$HISTORY_KEY" --file "$HISTORY_FILE" --force > /dev/null

echo "changed"
