#!/bin/bash

project_path=rasp

linux_path=linux
linux_ver=3.10
linux_url=https://github.com/raspberrypi/linux.git
linux_cross=~/projects/x-tools/arm-unknown-linux-gnueabi/bin/arm-unknown-linux-gnueabi-
linux_config_url=http://dl.hundeboll.net/rasp/rasp-aufs-kconfig-3.10

aufs_path=aufs3-standalone
aufs_ver=$linux_ver
aufs_url=git://git.code.sf.net/p/aufs/aufs3-standalone

bb_deb_url=http://archive.raspbian.org/raspbian/pool/main/b/busybox/busybox-static_1.20.0-9_armhf.deb
bb_deb_file=$(basename $bb_deb_url)
e2fs_deb_url=http://archive.raspbian.org/raspbian/pool/main/e/e2fsprogs/e2fsck-static_1.42.8-1_armhf.deb
e2fs_deb_file=$(basename $e2fs_deb_url)

cpio_path=initramfs
cpio_init_url=http://dl.hundeboll.net/rasp/rasp-aufs-init.sh
ntpc_path=ntpclient
ntpc_url=https://github.com/troglobit/ntpclient.git

boot_path=boot
boot_config_url=http://dl.hundeboll.net/rasp/rasp-boot-cfg.txt
boot_cmdline_url=http://dl.hundeboll.net/rasp/rasp-boot-cmd.txt

nfsroot_path=/srv/nfsroot
nfsroot_url=http://dl.hundeboll.net/rasp/rasp-nfsroot.tar.gz
nfsroot_file=$(basename $nfsroot_url)
nfsroot_ip=192.168.1.1
nfsroot_opts="(ro,fsid=root,async,no_root_squash,no_subtree_check)"
nfsroot_net=192.168.1.0/24

# check cross compiler
if [ ! -x ${linux_cross}gcc ]; then
    echo "Please make sure you have cross compiler tool-chain installed"
    echo "and configured this script to use it:"
    grep -E "^linux_cross" $0
    exit 1
fi

# check for ar to extract .deb files
if ! which ar &> /dev/null; then
    echo "Please install 'ar'"
    exit 1
fi

# check for cpio to create initramfs
if ! which cpio &> /dev/null; then
    echo "Please install 'cpio'"
    exit 1
fi

# check for git to get sources
if ! which git &> /dev/null; then
    echo "Please install 'git'"
    exit 1
fi

# create a project folder
if [ ! -d $project_path ]; then
    mkdir -p $project_path || exit 1
fi
cd $project_path
project_path=$(pwd)

# get and compile ntpclient
if [ ! -d $ntpc_path ]; then
    git clone $ntpc_url $ntpc_path || exit 1
fi

cd $ntpc_path
sed -i -E "s/CFLAGS([\t ]+)=/CFLAGS\1+=/" Makefile || exit 1
CC=${linux_cross}gcc CFLAGS="-static -static-libgcc" make || exit 1
cd ..

# create initramfs image
if [ ! -d $cpio_path ]; then
    mkdir -p $cpio_path || exit 1
fi

cd $cpio_path

# prepare fs layout
mkdir -p aufs bin dev etc lib proc rootfs rw sbin sys usr/{bin,sbin}
touch etc/mdev.conf
if [ ! -c dev/console ]; then sudo mknod -m 622 dev/console c 5 1 || exit 1; fi
if [ ! -c dev/tty0 ];    then sudo mknod -m 622 dev/tty0 c 4 0    || exit 1; fi
if [ ! -b dev/nfs ];     then sudo mknod -m 622 dev/nfs b 0 255   || exit 1; fi
if [ ! -c dev/null ];    then sudo mknod -m 622 dev/null c 1 3    || exit 1; fi

# install ntpclient
cp -a ../$ntpc_path/ntpclient bin/ntpclient

# get busybox
if [ ! -f ../$bb_deb_file ]; then
    wget $bb_deb_url -O ../$bb_deb_file || exit 1
fi

# extract busybox
ar p ../$bb_deb_file data.tar.gz | \
    tar zxf - ./bin/busybox -O > bin/busybox || exit 1

# install busybox and sh
chmod +x bin/busybox || exit 1
if [ ! -h bin/sh ]; then ln -s busybox bin/sh || exit 1; fi

# get e2fsck.static
if [ ! -f ../$e2fs_deb_file ]; then
    wget $e2fs_deb_url -O ../$e2fs_deb_file || exit 1
fi

# extract and install e2fsck.static
ar p ../$e2fs_deb_file data.tar.gz | \
    tar zxf - ./sbin/e2fsck.static -O > sbin/e2fsck.static || exit 1
chmod +x sbin/e2fsck.static || exit 1

# get init script
if [ ! -f init ]; then
    wget $cpio_init_url -O init || exit 1
fi

# install init script
chmod +x init || exit 1

# create initramfs image
find . | cpio -H newc -o > ../$linux_path/initramfs.cpio
cd ..

# get kernel source
if [ ! -d $linux_path ]; then
    git clone -b rpi-${linux_ver}.y $linux_url $linux_path || exit 1
fi

# get aufs source
if [ ! -d $aufs_path ]; then
    git clone -b aufs$aufs_ver $aufs_url $aufs_path || exit 1
fi

# setup and compile kernel
cd $linux_path

# patch kernel source
aufs_hdr_path=include/uapi/linux
git reset --hard HEAD
cp -a ../$aufs_path/fs .
cp -a ../$aufs_path/$aufs_hdr_path/aufs_type.h $aufs_hdr_path || exit 1
for p in aufs3-kbuild.patch aufs3-base.patch aufs3-mmap.patch; do
    git apply ../$aufs_path/$p || exit 1
done

# get config file
if [ ! -f .config ]; then
    wget $linux_config_url -O .config
fi

# configure kernel
make ARCH=arm CROSS_COMPILE=$linux_cross olddefconfig || exit 1
for o in CONFIG_BLK_DEV_INITRD \
         CONFIG_AUFS_FS \
         CONFIG_AUFS_EXPORT; do
    sed -i -E "s/.*${o}.*/${o}=y/" .config || exit 1

    # update config with new options
    make ARCH=arm CROSS_COMPILE=$linux_cross olddefconfig || exit 1
done
sed -i -E "s/.*(CONFIG_AUFS_BR_HFSPLUS).*/\1=n/" .config || exit 1
sed -i -E "s/.*(CONFIG_INITRAMFS_SOURCE).*/\1=\"initramfs.cpio\"/" .config || exit 1

# now compile it
make ARCH=arm CROSS_COMPILE=$linux_cross -j$(nproc) || exit 1
cd ..

# prepare boot folder
if [ ! -d $boot_path ]; then
    mkdir -p $boot_path || exit 1
fi

# prepare escaped strings for sed
i=$(echo $nfsroot_ip | sed -e 's/[\/&]/\\&/g') || exit 1
p=$(echo $nfsroot_path | sed -e 's/[\/&]/\\&/g') || exit 1
n=$(echo $nfsroot_net | sed -e 's/[\/&]/\\&/g') || exit 1
o=$(echo $nfsroot_opts | sed -e 's/[\/&]/\\&/g') || exit 1

# prepare boot files
cp $linux_path/arch/arm/boot/zImage $boot_path || exit 1
wget $boot_config_url -O $boot_path/config.txt || exit 1
wget $boot_cmdline_url -O $boot_path/cmdline.txt || exit 1
sed -i -E "s/nfsroot=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[\/0-9a-zA-Z]+/nfsroot=$i:$p/" \
    $boot_path/cmdline.txt || exit 1

# get and extract nfs root files
if [ ! -f $nfsroot_file ]; then
    wget $nfsroot_url -O $nfsroot_file || exit 1
fi
sudo tar pxf $project_path/$nfsroot_file -C $(dirname $nfsroot_path) || exit 1

# setup nfs exports
if grep -q $nfsroot_path /etc/exports; then
    sudo sed -E -i "s/^$p.*/$p $n$o/" /etc/exports || exit 1
else
    sudo echo "$nfsroot_path $nfsroot_net$nfsroot_opts" >> /etc/exports || exit 1
fi
sudo exportfs -rav || exit 1

# done :)
cat <<EOF

Done!

Now please start your nfs server and make sure it is listening on $nfsroot_ip

  On systemd-based distributions:
  $ sudo systemctl start rpc-idmapd
  $ sudo systemctl start rpc-mounts

  On debian/ubuntu:
  $ sudo service nfs-kernel-server start

Then copy the contents of
  $project_path/$boot_path
to the first partion on the sd-card and enjoy network booting with copy-on-write
overlay filesystem :)

EOF
