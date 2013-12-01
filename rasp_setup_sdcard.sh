#!/bin/bash

dev=$1
path=$2

if [ "$dev" == "" ]; then
    echo "Please specify device to setup"
    exit 1
fi

if [ ! -b $dev ]; then
    echo "$dev is not a block device"
    exit 1
fi

if [ "$dev" == "/dev/sda" ]; then
    echo "I refuse to work with $dev"
    exit 1
fi

if [ "$path" == "" ] || [ ! -d $path ]; then
    echo "Please specify a folder with boot content"
    exit 1
fi

echo Configuring $dev
echo Using $path

# make sure the device is not mounted
for i in $(seq 10); do
	if [ -b $dev$i ] &&  mount | grep -q $dev$i; then
		echo umount $dev$i
		sudo umount $dev$i
	fi
done

# clear and add fat partition for boot
(echo o; echo n; echo p; echo 1; echo ; echo +100M; echo t; echo b; echo w) | sudo fdisk $dev || exit 1

# add linux partition for home
(echo n; echo p; echo 2; echo ; echo ; echo w) | sudo fdisk $dev || exit 1

# make fat fs
sudo mkfs.vfat -n BOOT ${dev}1 || exit 1

# make ext4 fs
sudo mkfs.ext4 -L HOME ${dev}2 || exit 1

# mount and copy contents to boot
sudo mount ${dev}1 /mnt || exit 1
sudo cp $path/* /mnt/ || exit 1
sync || exit 1
sudo umount /mnt || exit 1

# mount and create home folder on home
sudo mount ${dev}2 /mnt || exit 1
sudo mkdir /mnt/pi || exit 1
sudo chown -R 1000:1000 /mnt/pi || exit 1
sync || exit 1
sudo umount /mnt || exit 1

echo "Done"
