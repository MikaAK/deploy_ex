#! /usr/bin/env bash
# Usage: latest_oci_release.sh <bucket> <namespace> <app_name> <release_prefix>
#
# OCI Object Storage equivalent of latest_aws_release.sh. Object names returned by the
# oci CLI are already relative to the bucket (unlike `aws s3 ls`, which prints
# "bucket/key"), so no bucket-name stripping is needed here.

BUCKET_NAME="$1"
NAMESPACE="$2"
APP_NAME="$3"
RELEASE_PREFIX="$4"

if [ -n "$RELEASE_PREFIX" ]; then
  OBJECT_PREFIX="$RELEASE_PREFIX/$APP_NAME"
else
  OBJECT_PREFIX="$APP_NAME"
fi

# The oci CLI prints NOTHING (not "[]") when a list matches no resources, and jq treats
# empty input as producing no output, so this needs no special-case handling.
oci_files_for_app=$(oci os object list --namespace "$NAMESPACE" --bucket-name "$BUCKET_NAME" --prefix "$OBJECT_PREFIX" --all --query 'data[*].name' --output json | jq -r '.[]' | sort -r | head -n 1)

if [ -z "$oci_files_for_app" ] && [ -n "$RELEASE_PREFIX" ]; then
  oci_files_for_app=$(oci os object list --namespace "$NAMESPACE" --bucket-name "$BUCKET_NAME" --prefix "$APP_NAME" --all --query 'data[*].name' --output json | jq -r '.[]' | sort -r | head -n 1)
fi

echo "$oci_files_for_app"
