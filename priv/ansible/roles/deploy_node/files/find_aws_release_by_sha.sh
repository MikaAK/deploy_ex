#! /usr/bin/env bash
# Usage: find_aws_release_by_sha.sh <bucket> <app_name> <release_prefix> <target_sha>

BUCKET_NAME="$1"
APP_NAME="$2"
RELEASE_PREFIX="$3"
TARGET_SHA="$4"

if [ -n "$RELEASE_PREFIX" ]; then
  BUCKET_PATH="$BUCKET_NAME/$RELEASE_PREFIX/$APP_NAME"
else
  BUCKET_PATH="$BUCKET_NAME/$APP_NAME"
fi

# List all files, filter by SHA, return first match (should match release naming convention)
match=$(aws s3 ls "$BUCKET_PATH" --recursive | awk '{ print $4 }' | grep "$TARGET_SHA" | head -n 1)

if [ -z "$match" ] && [ -n "$RELEASE_PREFIX" ]; then
  match=$(aws s3 ls "$BUCKET_NAME/$APP_NAME" --recursive | awk '{ print $4 }' | grep "$TARGET_SHA" | head -n 1)
fi

echo "$match" | sed 's/'"$BUCKET_NAME"'\///'
