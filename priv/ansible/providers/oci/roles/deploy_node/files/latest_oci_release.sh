#! /usr/bin/env bash
# Usage: latest_oci_release.sh <bucket> <namespace> <app_name> <release_prefix>
#
# OCI Object Storage equivalent of latest_aws_release.sh. Object names returned by the
# oci CLI are already relative to the bucket (unlike `aws s3 ls`, which prints
# "bucket/key"), so no bucket-name stripping is needed here.
set -uo pipefail

BUCKET_NAME="$1"
NAMESPACE="$2"
APP_NAME="$3"
RELEASE_PREFIX="$4"

# A failed lookup MUST NOT reach stdout. MEASURED: with instance principals unconfigured, the
# CLI's "ServiceError:" banner was taken as the release name and the caller ran
# `oci os object get --name 'ServiceError:'`, turning an auth failure into a confusing 404 on
# a nonsense object. Every lookup therefore checks the exit status and refuses to print
# anything that is not a plausible object key.
list_objects() {
  local prefix="$1"
  local output status

  output=$(oci os object list --namespace "$NAMESPACE" --bucket-name "$BUCKET_NAME" \
    --prefix "$prefix" --all --query 'data[*].name' --output json 2>&1)
  status=$?

  if [ $status -ne 0 ]; then
    echo "latest_oci_release.sh: listing '$prefix' in '$BUCKET_NAME' failed (exit $status)" >&2
    echo "$output" >&2
    return $status
  fi

  # The oci CLI prints NOTHING (not "[]") when a list matches no resources, and jq treats
  # empty input as producing no output, so an empty bucket is not an error here.
  printf '%s' "$output" | jq -r '.[]' 2>/dev/null | sort -r | head -n 1
}

release=$(list_objects "${RELEASE_PREFIX:+$RELEASE_PREFIX/}$APP_NAME") || exit $?

if [ -z "$release" ] && [ -n "$RELEASE_PREFIX" ]; then
  release=$(list_objects "$APP_NAME") || exit $?
fi

echo "$release"
