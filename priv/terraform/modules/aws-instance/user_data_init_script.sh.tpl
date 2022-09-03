#!/bin/bash

instance_name=$(echo ${instance_name} | tr -d ' ' | sed 's/[[:upper:]]/-&/g;s/^-//' | tr '[:upper:]' '[:lower:]')

echo "Setting preserve hostname to true..." &&
sudo sed -i 's/preserve_hostname: false/preserve_hostname: true/' /etc/cloud/cloud.cfg &&
echo "Setting hostname to $instance_name" &&
sudo hostnamectl set-hostname $instance_name
