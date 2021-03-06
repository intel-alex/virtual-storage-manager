#!/bin/bash

# Copyright 2014 Intel Corporation, All Rights Reserved.

# Licensed under the Apache License, Version 2.0 (the"License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at

#  http://www.apache.org/licenses/LICENSE-2.0

# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied. See the License for the
# specific language governing permissions and limitations
# under the License.

#-------------------------------------------------------------------------------
#            Usage
#-------------------------------------------------------------------------------

function usage() {
    cat << EOF
Usage: install.sh

Auto deploy vsm:
    The tool can help you to deploy the vsm envirement automatically.
    Please run such as bash +x install.sh

Options:
  --help | -h
    Print usage information.
  --manifest [manifest directory] | -m [manifest directory]
    The directory to store the server.manifest and cluster.manifest.
  --version [master] | -v [master]
    The version of vsm dependences to download(Default=master).
EOF
    exit 0
}

MANIFEST_PATH=""
dependence_version="master"
while [ $# -gt 0 ]; do
  case "$1" in
    -h) usage ;;
    --help) usage ;;
    -m| --manifest) MANIFEST_PATH=$2 ;;
    -v| --version) dependence_version=$2 ;;
    *) shift ;;
  esac
  shift
done


set -e
set -o xtrace

echo "Before auto deploy the vsm, please be sure that you have set the manifest 
such as manifest/192.168.100.100/server.manifest. And you have changed the file, too."
sleep 5

TOPDIR=$(cd $(dirname "$0") && pwd)
TEMP=`mktemp`; rm -rfv $TEMP >/dev/null; mkdir -p $TEMP;

HOSTNAME=`hostname`
#HOSTIP=`hostname -I|sed s/[[:space:]]//g`
HOSTIP=`hostname -I`

source $TOPDIR/hostrc

is_controller=0
for ip in $HOSTIP; do
    if [ $ip == $controller_ip ]; then
        is_controller=1
    fi
done

if [ $is_controller -eq 0 ]; then
    echo "[Info]: You run the tool in a third server."
else
    echo "[Info]: You run the tool in the controller server."
fi


#-------------------------------------------------------------------------------
#            checking packages
#-------------------------------------------------------------------------------

echo "+++++++++++++++start checking packages+++++++++++++++"

if [ ! -d ../vsmrepo ]; then
    echo "You should have the vsmrepo folder, please check and try again"
    exit 1
fi

cd ../vsmrepo
is_python_vsmclient=`ls|grep python-vsmclient*.rpm|wc -l`
is_vsm=`ls|grep -v python-vsmclient|grep -v vsm-dashboard|grep -v vsm-deploy|grep vsm|wc -l`
is_vsm_dashboard=`ls|grep vsm-dashboard*.rpm|wc -l`
is_vsm_deploy=`ls|grep vsm-deploy*.rpm|wc -l`
if [ $is_python_vsmclient -gt 0 ] && [ $is_vsm -gt 0 ] && [ $is_vsm_dashboard -gt 0 ] && [ $is_vsm_deploy -gt 0 ]; then
    echo "The vsm pachages have been already prepared"
else
    echo "please check the vsm packages, then try again"
    exit 1
fi

cd $TOPDIR
echo "+++++++++++++++finish checking packages+++++++++++++++"


#-------------------------------------------------------------------------------
#            setting the iptables and selinux
#-------------------------------------------------------------------------------

echo "+++++++++++++++start setting the iptables and selinux+++++++++++++++"

function set_iptables_selinux() {
    ssh root@$1 "service iptables stop"
    ssh root@$1 "chkconfig iptables off"
    ssh root@$1 "sed -i \"s/SELINUX=enforcing/SELINUX=disabled/g\" /etc/selinux/config"
    ssh root@$1 "setenforce 0"
}

if [ $is_controller -eq 0 ]; then
    set_iptables_selinux $controller_ip
else
    service iptables stop
    chkconfig iptables off
    sed -i "s/SELINUX=enforcing/SELINUX=disabled/g" /etc/selinux/config
    setenforce 0
fi

for ip in $storage_ip_list; do
    set_iptables_selinux $ip
done

echo "+++++++++++++++finish setting the iptables and selinux+++++++++++++++"


#-------------------------------------------------------------------------------
#            downloading the dependences
#-------------------------------------------------------------------------------

if [ ! -d /opt/vsmrepo ] && [ ! -d vsmrepo ]; then
    wget https://github.com/01org/vsm-dependencies/archive/"$dependence_version".zip
    unzip $dependence_version
    mv vsm-dependencies-$dependence_version/repo vsmrepo
    rm -rf vsm-dependencies-$dependence_version
    rm -rf $dependence_version
fi

if [ $is_controller -eq 0 ]; then
    ssh root@$controller_ip "rm -rf /opt/vsmrepo"
    scp -r vsmrepo root@$controller_ip:/opt
else
    if [ -d vsmrepo ]; then
        rm -rf /opt/vsmrepo
        cp -rf vsmrepo /opt
    fi
fi


#-------------------------------------------------------------------------------
#            setting the repo
#-------------------------------------------------------------------------------

echo "+++++++++++++++start setting the repo+++++++++++++++"

rm -rf vsm.repo
cat <<"EOF" >vsm.repo
[vsmrepo]
name=vsmrepo
baseurl=file:///opt/vsmrepo
gpgcheck=0
enabled=1
proxy=_none_
EOF

oldurl="file:///opt/vsmrepo"
newurl="http://$controller_ip/vsmrepo"
if [ $is_controller -eq 0 ]; then
    scp vsm.repo root@$controller_ip:/etc/yum.repos.d
    ssh root@$controller_ip "yum makecache; yum -y install httpd; service httpd restart; rm -rf /var/www/html/vsmrepo; cp -rf /opt/vsmrepo /var/www/html"
    ssh root@$controller_ip "sed -i \"s,$oldurl,$newurl,g\" /etc/yum.repos.d/vsm.repo; yum makecache"
else
    cp vsm.repo /etc/yum.repos.d
    yum makecache; yum -y install httpd; service httpd restart; rm -rf /var/www/html/vsmrepo; cp -rf /opt/vsmrepo /var/www/html
    sed -i "s,$oldurl,$newurl,g" /etc/yum.repos.d/vsm.repo
    yum makecache
fi

sed -i "s,$oldurl,$newurl,g" vsm.repo

function set_repo() {
    ssh root@$1 "rm -rf /etc/yum.repos.d/vsm.repo"
    scp vsm.repo root@$1:/etc/yum.repos.d
    ssh root@$1 "yum makecache"
}

for ip in $storage_ip_list; do
    set_repo $ip
done

echo "+++++++++++++++finish setting the repo+++++++++++++++"


#-------------------------------------------------------------------------------
#            install vsm rpm and dependences
#-------------------------------------------------------------------------------

echo "+++++++++++++++install vsm rpm and dependences+++++++++++++++"

function install_vsm_dependences() {
    ssh root@$1 "mkdir -p /opt/vsm_install"
    scp ../vsmrepo/python-vsmclient*.rpm ../vsmrepo/vsm*.rpm root@$1:/opt/vsm_install
    ssh root@$1 "cd /opt/vsm_install; yum -y localinstall python-vsmclient*.rpm vsm*.rpm"
    ssh root@$1 "preinstall"
    ssh root@$1 "cd /opt; rm -rf /opt/vsm_install"
}

if [ $is_controller -eq 0 ]; then
    install_vsm_dependences $controller_ip
else
    yum -y localinstall ../vsmrepo/python-vsmclient*.rpm ../vsmrepo/vsm*.rpm
    preinstall
fi

for ip in $storage_ip_list; do
    install_vsm_dependences $ip
done

echo "+++++++++++++++finish install vsm rpm and dependences+++++++++++++++"


#-------------------------------------------------------------------------------
#            setup vsm controller node
#-------------------------------------------------------------------------------

if [ -z $MANIFEST_PATH ]; then
    MANIFEST_PATH="manifest"
fi

function setup_controller() {
    ssh root@$controller_ip "rm -rf /etc/manifest/cluster_manifest"
    scp $MANIFEST_PATH/$controller_ip/cluster.manifest root@$controller_ip:/etc/manifest
    ssh root@$controller_ip "chown root:vsm /etc/manifest/cluster.manifest; chmod 755 /etc/manifest/cluster.manifest"
    is_cluster_manifest_error=`ssh root@$controller_ip "cluster_manifest|grep error|wc -l"`
    if [ $is_cluster_manifest_error -gt 0 ]; then
        echo "please check the cluster.manifest, then try again"
        exit 1
    else
        ssh root@$controller_ip "vsm-controller"
    fi
}

if [ $is_controller -eq 0 ]; then
    setup_controller
else
    rm -rf /etc/manifest/cluster.manifest
    cp $MANIFEST_PATH/$controller_ip/cluster.manifest /etc/manifest
    chown root:vsm /etc/manifest/cluster.manifest
    chmod 755 /etc/manifest/cluster.manifest
    if [ `cluster_manifest|grep error|wc -l` -gt 0 ]; then
        echo "please check the cluster.manifest, then try again"
        exit 1
    else
        vsm-controller
    fi
fi


#-------------------------------------------------------------------------------
#            setup vsm storage node
#-------------------------------------------------------------------------------

count_ip=0
for ip in $storage_ip_list; do
    let count_ip=$count_ip+1
done
let count_ip=$count_ip+2+1
if [ `ls $MANIFEST_PATH|wc -l` != $count_ip ]; then
    echo "please check the manifest folder"
    exit 1
fi

success=""
failure=""
if [ $is_controller -eq 0 ]; then
    token=`ssh root@$controller_ip "agent-token"`
else
    token=`agent-token`
fi

function setup_storage() {
    ssh root@$1 "rm -rf /etc/manifest/server.manifest"
    sed -i "s/token-tenant/$token/g" $MANIFEST_PATH/$1/server.manifest
    old_str=`cat $MANIFEST_PATH/$1/server.manifest| grep ".*-.*" | grep -v by | grep -v "\["`
    sed -i "s/$old_str/$token/g" $MANIFEST_PATH/$1/server.manifest
    scp $MANIFEST_PATH/$1/server.manifest root@$1:/etc/manifest
    ssh root@$1 "chown root:vsm /etc/manifest/server.manifest; chmod 755 /etc/manifest/server.manifest"
    is_server_manifest_error=`ssh root@$1 "server_manifest|grep error|wc -l"`
    if [ $is_server_manifest_error -gt 0 ]; then
        echo "[warning]: The server.manifest in $1 is wrong, so fail to setup in $1 storage node"
        failure=$failure"$1 "
    else
        ssh root@$1 "vsm-node"
        success=$success"$1 "
    fi
}

for ip in $storage_ip_list; do
    setup_storage $ip
done


#-------------------------------------------------------------------------------
#            finish auto deploy
#-------------------------------------------------------------------------------

echo "Successful storage node ip: $success"
echo "Failure storage node ip: $failure"

set +o xtrace


# change_log
# Feb 12 2015 Zhu Boxiang <boxiangx.zhu@intel.com> - 2015.2.12-1
# Initial release
# 
# 
# 