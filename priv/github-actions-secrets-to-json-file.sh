#! /usr/env/bin bash
echo "{\"secrets\": \"" > $1

for s in $(echo "$2" | jq -r "to_entries|map(\"\(.key)=\(.value|tostring)\")|.[]" ); do
  if [[ "$s" == __DEPLOY_EX__* ]]; then
    echo "Environment=$(echo $s | sed 's/__DEPLOY_EX__//')\n" >> $1
  fi
done

echo "\"}" >> $1
