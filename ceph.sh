#!/bin/bash
ceph_user=$USER									# ceph 工作目录的拥有者
mds_hostname="AEP-52"							# MDS 主机名
osd_hostname=("AEP-53")		# OSD 主机名
osd_id=(0)									# OSD ID
osd_pmem=("/dev/pmem12")	# OSD使用的PMEM
osd_num=${#osd_hostname[*]}						# OSD的个数
cephfs_mount_point="/mnt/cephfs"				# ceph挂载点

# 出错则退出
set -o errexit
# alias ee='echo -e "\033[;32m"'
# color_mode='-e \033[;32m'

# ceph 工作目录
work_dir=("/etc/ceph")
work_dir=(${work_dir[*]} "/var/lib/ceph")
work_dir=(${work_dir[*]} "/var/run/ceph")

init_env() {
	sudo modprobe ib_uverbs
	for dir in ${work_dir[@]}; do
		# echo $dir
		if [ ! -d $dir ]; then
			sudo mkdir $dir
		fi
		sudo chmod -R 777 $dir
		echo sudo chown -R $ceph_user:$ceph_user $dir
		sudo chown -R $ceph_user:$ceph_user $dir
	done
}

start_osd() {
	for((i=0; i<$osd_num; i++)) do
		if [ `hostname` = ${osd_hostname[i]} ]; then
			mount_point="/var/lib/ceph/osd/ceph-${osd_id[i]}"
			if [ `mount | grep ${osd_pmem[i]} | wc -l` = "1" ]; then
				echo "unmount ${osd_pmem[i]}"
				sudo umount ${osd_pmem[i]}
			fi
			echo "mount ${osd_pmem[i]} at $mount_point"
			sudo mount -o user_xattr,dax ${osd_pmem[i]} $mount_point
			ceph-osd -i ${osd_id[i]}
		fi
	done
}

start_mds() {
	if [ `hostname` = $mds_hostname ]; then
		# killall ceph-mon ceph-mgr ceph-mds
		stop_mds
		ceph-mon -i $mds_hostname
		ceph-mgr -i $mds_hostname
		ceph-mds -i $mds_hostname -m $mds_hostname:6789
	fi
}

stop_osd() {
	umount_ceph
	for((i=0; i<$osd_num; i++)) do
		if [ `hostname` = ${osd_hostname[i]} ]; then
			echo Stopping osd.$i
			mount_point="/var/lib/ceph/osd/ceph-${osd_id[i]}"
			if [ `ps -aux | grep ceph-osd | wc -l` != 1 ]; then sudo killall ceph-osd; fi
			if [ `mount | grep ${osd_pmem[i]} | wc -l` = "1" ]; then
				echo sleeping 
				sleep 7
				echo sudo umount $mount_point
				sudo umount $mount_point
			fi
		fi
	done
}

stop_mds() {
	umount_ceph
	if [ `hostname` = $mds_hostname ]; then
		if [ `ps -aux | grep ceph | wc -l` != 1 ]; then echo Stopping mds@$mds_hostname; fi
		if [ `ps -aux | grep ceph-mds | wc -l` != 1 ]; then sudo killall ceph-mds; fi
		if [ `ps -aux | grep ceph-mgr | wc -l` != 1 ]; then sudo killall ceph-mgr; fi
		if [ `ps -aux | grep ceph-mon | wc -l` != 1 ]; then sudo killall ceph-mon; fi
	fi
}

remove_fs() {
	if [ `hostname` != $mds_hostname ];then return; fi
	if [ `ps -aux | grep ceph-mds | wc -l` != 1 ]; then sudo killall ceph-mds; fi
	ceph mds fail $mds_hostname
	if [ `ceph fs ls | grep cephfs | wc -l` = "1" ]; then
		echo ceph fs rm cephfs --yes-i-really-mean-it
		ceph fs rm cephfs --yes-i-really-mean-it
	fi
	# remove osd
	for id in `ceph osd ls`; do
		echo ceph$h
		ceph osd down $id
		ceph osd rm $id
		ceph osd crush rm osd.$id
		# ceph auth rm osd.$ID
	done
	for((i=0; i<$osd_num; i++)); do
		ceph osd crush rm ${osd_hostname[i]}
	done
	# remove pool
	for pool in `ceph osd pool ls`; do
		ceph osd pool delete $pool $pool --yes-i-really-really-mean-it
	done
}

rebuild_fs() {
	if [ `hostname` != $mds_hostname ];then return; fi
	if [ `ceph fs ls | grep cephfs | wc -l` != "1" ];then
		ceph osd pool create cephfs_data 128
		ceph osd pool create cephfs_metadata 32
		ceph fs new cephfs cephfs_metadata cephfs_data
	fi
	ceph-mds -i `hostname` -m `hostname`:6789
}

rebuild_osd() {
	if [ `ceph osd ls | wc -l` = 0 ]; then 
		for ((i=0; i<$osd_num; i++)); do
			ceph osd create
		done
	fi
	for((i=0; i<$osd_num; i++)) do
		if [ `hostname` = ${osd_hostname[i]} ]; then
			echo "rebuilding osd ${osd_hostname[i]}"
			mount_point="/var/lib/ceph/osd/ceph-${osd_id[i]}"
			if [ `ps -aux | grep ceph-osd | wc -l` != 1 ]; then killall ceph-osd; fi
			if [ `mount | grep ${osd_pmem[i]} | wc -l` = "1" ]; then
				echo sudo umount $mount_point
				sudo umount $mount_point
			fi
			if [ ! -d $mount_point ]; then
				mkdir -p $mount_point
			fi
			echo sudo mkfs.ext4 -F ${osd_pmem[i]}
			sudo mkfs.ext4 -F ${osd_pmem[i]} 1>/dev/null
			echo "mount ${osd_pmem[i]} at $mount_point"
			sudo mount -o user_xattr,dax ${osd_pmem[i]} $mount_point
			sudo chown -R $ceph_user:$ceph_user $mount_point
			ceph-osd -f -i ${osd_id[i]} --mkfs --mkkey 1>/dev/null
			# echo ------------------------------
			# echo ceph-osd -i ${osd_id[i]}
			# echo ------------------------------
			ceph-osd -i ${osd_id[i]}
		fi
	done
}

mount_ceph() {
	echo mount cephfs at $cephfs_mount_point
	if [ ! -d $cephfs_mount_point ]; then
		sudo mkdir $cephfs_mount_point
		sudo chown $ceph_user:$ceph_user $cephfs_mount_point
	fi
	if [ `mount | grep fuse.ceph-fuse | wc -l` = 0 ];then
		sudo ceph-fuse -m $mds_hostname:6789 $cephfs_mount_point
	fi
	sudo chown $ceph_user:$ceph_user $cephfs_mount_point
}

umount_ceph() {
	if [ `mount | grep fuse.ceph-fuse | wc -l` != 0 ];then
		echo "umount cephfs at $cephfs_mount_point " 
		sudo umount $cephfs_mount_point
	fi
}

set_replica() {
	ceph_conf_file="/etc/ceph/ceph.conf"
	echo changing $ceph_conf_file: osd pool default size = $1
	sed -i "s/osd pool default size = .*/osd pool default size = $1/g" $ceph_conf_file
	start_mds
	stop_osd
	remove_fs
	rebuild_osd
	rebuild_fs
}

get_replica() {
	daemon_name=none
	if [ `hostname` = $mds_hostname ];then daemon_name="mon.$mds_hostname"; fi
	for((i=0; i<$osd_num; i++)) do
		if [ `hostname` = ${osd_hostname[i]} ]; then
			daemon_name="osd.${osd_id[i]}"
		fi
	done
	if [ $daemon_name = none ];then return; fi
	s1=`ceph daemon $daemon_name config show | grep osd_pool_default_size`
	echo $s1
}

check_replica() {
	daemon_name=none
	if [ `hostname` = $mds_hostname ];then daemon_name="mon.$mds_hostname"; fi
	for((i=0; i<$osd_num; i++)) do
		if [ `hostname` = ${osd_hostname[i]} ]; then
			daemon_name="osd.${osd_id[i]}"
		fi
	done
	if [ $daemon_name = none ];then return; fi
	echo ceph daemon $daemon_name config show grep osd_pool_default_size
	s1=`ceph daemon $daemon_name config show | grep osd_pool_default_size`
	s2="    \"osd_pool_default_size\": \"$1\","
	echo $s1
	echo $s2
	if [ "$s1" != "$s2" ]; then
		echo "check failed"
		echo $s1
		exit 1
	else
		echo The number of replications is OK: $1
	fi 
}

# start		启动mds osd守护进程
# mount		挂载cephfs
# umount	卸载cephfs
# stop		卸载并停止守护进程,如果是osd会卸载挂载的pmem
# rebuild	在守护进程运行的情况下,重建cephfs,这里用于解决出现了一致性问题的情况


main() {
	init_env
	if [ $# = 0 ]; then 
		echo "至少传入一个参数"
		return
	fi
	if [ x$1 = xstart ]; then
		start_mds
		start_osd
	elif [ x$1 = xmount ]; then
		mount_ceph
	elif [ x$1 = xumount ]; then
		umount_ceph
	elif [ x$1 = xstop ]; then
		stop_mds
		stop_osd
	elif [ x$1 = xrebuild ]; then
		remove_fs
		rebuild_osd
		rebuild_fs
	elif [ x$1 = x-r ]; then
		set_replica $2
		check_replica $2
	elif [ x$1 = x-g ]; then
		get_replica
	else
		echo "传入的参数有误"
	fi
}

main $*
