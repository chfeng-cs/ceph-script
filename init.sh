#!/bin/bash

set -u 

ceph_dir=/etc/ceph
ceph_conf_file=$ceph_dir/ceph.conf
# echo $ceph_conf_file $ceph_dir

own=`whoami`:`whoami`

cd `dirname $0`

if [ ! -d $ceph_dir ]; then 
    sudo mkdir $ceph_dir;
    sudo chown $own -R $ceph_dir
fi

if [ ! -f $ceph_conf_file ]; then 
    cp ceph.conf $ceph_conf_file
fi

sudo mkdir -p /var/lib/ceph/mon/
sudo chown $own /var/lib/ceph

# monmaptool --create --add AEP-50 10.0.0.50 --fsid 167b6ea3-2873-440c-89c4-73e7f6f45fa8 /tmp/monmap
# ceph-mon --mkfs -i AEP-50 --monmap /tmp/monmap