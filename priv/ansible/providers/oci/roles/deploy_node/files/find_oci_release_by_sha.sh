#! /usr/bin/env bash
# Usage: find_oci_release_by_sha.sh <bucket> <namespace> <app_name> <release_prefix> <target_sha>
set -uo pipefail

BUCKET_NAME="$1"
NAMESPACE="$2"
APP_NAME="$3"
RELEASE_PREFIX="$4"
TARGET_SHA="$5"

# A failed lookup MUST NOT reach stdout. MEASURED: with instance principals unconfigured, the
# CLI's "ServiceError:" banner was taken as the release name and the caller ran
# `oci os object get --name 'ServiceError:'`, turning an auth failure into a confusing 404 on
# a nonsense object.
find_matching() {
  local prefix="$1"
  local output status

  output=$(oci os object list --namespace "$NAMESPACE" --bucket-name "$BUCKET_NAME" \
    --prefix "$prefix" --all --query 'data[*].name' --output json 2>&1)
  status=$?

  if [ $status -ne 0 ]; then
    echo "find_oci_release_by_sha.sh: listing '$prefix' in '$BUCKET_NAME' failed (exit $status)" >&2
    echo "$output" >&2
    return $status
  fi

  # The oci CLI prints NOTHING (not "[]") when a list matches no resources, and jq treats
  # empty input as producing no output, so no match is not an error here.
  printf '%s' "$output" | jq -r '.[]' 2>/dev/null | grep "$TARGET_SHA" | head -n 1
}

match=$(find_matching "${RELEASE_PREFIX:+$RELEASE_PREFIX/}$APP_NAME") || exit $?

if [ -z "$match" ] && [ -n "$RELEASE_PREFIX" ]; then
  match=$(find_matching "$APP_NAME") || exit $?
fi

echo "$match"
