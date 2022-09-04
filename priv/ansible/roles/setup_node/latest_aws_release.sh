#! /usr/bin/env bash

aws_files_for_app=$(aws s3 ls $1/$2 --recursive | awk '{ print $4 }' | sed 's/'"$1"'\///')
echo $(echo $aws_files_for_app | sort -r | head)
