#!/bin/bash

echo "Mounting EBS Volume..."

sudo file -s /dev/sdh &&
sudo apt-get install xfsprogs &&
sudo mkfs -t xfs /dev/sdh &&
sudo mkdir /data &&
sudo mount /dev/sdh /data &&
echo "EBS Volume Mounted to /data, ensuring it attaches at restart..." &&
DATA_DEVICE_UUID=$(sudo lsblk -o +UUID | grep /data |  awk '{print $8}')
sudo echo "UUID=$DATA_DEVICE_UUID /data  xfs  defaults,nofail  0  2" >> /etc/fstab

echo "EBS volume setup for restart, ensuring it survives..."

sudo umount /data && sudo mount -a && echo "EBS volume restartability validated"
