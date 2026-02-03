#! /usr/bin/env bash
# Usage: latest_aws_release.sh <bucket> <app_name> <release_prefix>

BUCKET_NAME="$1"
APP_NAME="$2"
RELEASE_PREFIX="$3"

if [ -n "$RELEASE_PREFIX" ]; then
  BUCKET_PATH="$BUCKET_NAME/$RELEASE_PREFIX/$APP_NAME"
else
  BUCKET_PATH="$BUCKET_NAME/$APP_NAME"
fi

aws_files_for_app=$(aws s3 ls "$BUCKET_PATH" --recursive | awk '{ print $4 }' | sort -r | head -n 1)

if [ -z "$aws_files_for_app" ] && [ -n "$RELEASE_PREFIX" ]; then
  aws_files_for_app=$(aws s3 ls "$BUCKET_NAME/$APP_NAME" --recursive | awk '{ print $4 }' | sort -r | head -n 1)
fi

echo "$aws_files_for_app" | sed 's/'"$BUCKET_NAME"'\///'
