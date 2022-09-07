#! /usr/bin/env bash

sudo file -s /dev/sdh &&
sudo apt-get update -y &&
sudo apt-get install xfsprogs -y &&
sudo mkfs -t xfs /dev/sdh

sudo mkdir -p /data &&
sudo mount /dev/sdh /data &&
DATA_DEVICE_UUID=$(sudo lsblk -o +UUID | grep /data |  awk '{print $8}')

if [[ -z $DATA_DEVICE_UUID ]]; then
  sudo echo "UUID=$DATA_DEVICE_UUID /data  xfs  defaults,nofail  0  2" >> /etc/fstab

  sudo umount /data && sudo mount -a
else
  exit 1
fi
