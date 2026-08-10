#! /usr/bin/env bash
# Usage: find_oci_release_by_sha.sh <bucket> <namespace> <app_name> <release_prefix> <target_sha>

BUCKET_NAME="$1"
NAMESPACE="$2"
APP_NAME="$3"
RELEASE_PREFIX="$4"
TARGET_SHA="$5"

if [ -n "$RELEASE_PREFIX" ]; then
  OBJECT_PREFIX="$RELEASE_PREFIX/$APP_NAME"
else
  OBJECT_PREFIX="$APP_NAME"
fi

# List all objects, filter by SHA, return first match (should match release naming convention).
# The oci CLI prints NOTHING (not "[]") when a list matches no resources, and jq treats empty
# input as producing no output, so this needs no special-case handling.
match=$(oci os object list --namespace "$NAMESPACE" --bucket-name "$BUCKET_NAME" --prefix "$OBJECT_PREFIX" --all --query 'data[*].name' --output json | jq -r '.[]' | grep "$TARGET_SHA" | head -n 1)

if [ -z "$match" ] && [ -n "$RELEASE_PREFIX" ]; then
  match=$(oci os object list --namespace "$NAMESPACE" --bucket-name "$BUCKET_NAME" --prefix "$APP_NAME" --all --query 'data[*].name' --output json | jq -r '.[]' | grep "$TARGET_SHA" | head -n 1)
fi

echo "$match"
