#! /usr/bin/env bash

current_branch=$(git symbolic-ref --short -q HEAD)
git_file_diffs=$(git diff --name-only $current_branch | grep deploys/)

if [[ -z $git_file_diffs ]]; then
  echo "No files changed"
else
  echo "Files changed, adding to github..."
  echo $git_file_diffs

  git config user.name "Github Actions Bot"
  git config user.email mika@kalathil.me

  git add ./deploys &&
  git commit -m ":robot: Terraform updates from Github Actions" &&
  git push origin $current_branch
fi
