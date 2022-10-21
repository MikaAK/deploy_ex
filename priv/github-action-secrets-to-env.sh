#! /usr/bin/env bash
env_json=$(cat $1)

for s in $(echo $env_json | jq -r "to_entries|map(\"\(.key)=\(.value|tostring)\")|.[]" ); do
  if [[ "$s" == __DEPLOY_EX__* ]]; then
    echo -n " $(echo $s | xargs | sed 's/__DEPLOY_EX__//')"
  fi
done
