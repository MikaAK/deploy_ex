#! /usr/bin/env bash
# Usage: find_aws_release_by_sha.sh <bucket> <app_path> <target_sha>

BUCKET_PATH="$1/$2"
TARGET_SHA="$3"

# List all files, filter by SHA, return first match (should match release naming convention)
aws s3 ls "$BUCKET_PATH" --recursive | awk '{ print $4 }' | grep "$TARGET_SHA" | head -n 1 | sed 's/'"$1"'\///'
