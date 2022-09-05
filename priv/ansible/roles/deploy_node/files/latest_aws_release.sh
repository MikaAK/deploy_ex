#! /usr/bin/env bash

aws_files_for_app=$(aws s3 ls $1/$2 --recursive | awk '{ print $4 }' | sort -r | head -n 1 | sed 's/'"$1"'\///')
echo $aws_files_for_app
