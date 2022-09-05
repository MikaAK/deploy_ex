#! /usr/env/bash

if [[$(git diff --name-only head)]]; then
  echo "No files changed"
else
  echo "Files changed, adding to github..."

  git add . && git commit -m ":robot: Terraform updates from Github Actions" && git push origin/$(git symbolic-ref --short -q HEAD)
fi
