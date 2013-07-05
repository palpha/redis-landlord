#!/bin/bash

# exit codes:
# 1) invalid command
# 2) invalid id
# 3) invalid port

set -e

echoerr() { echo "$@" 1>&2; }

cmds=("setup" "disable" "enable" "delete")
cmd=$1
id=$2
available=/etc/init.d/redis-available
enabled=/etc/init.d/redis-enabled
bootstrapper=/etc/init.d/redis-tenants
confdir=/etc/redis

if [[ ! " ${cmds[@]} " =~ " ${cmd//[^a-z]/} " ]]; then
  old_ifs=$IFS
  IFS=','
  echo "Usage: $0 <command> [arg [arg...]]"
  cmds="${cmds[*]}"
  echo "Command is one of the following: ${cmds//,/, }"
  echo "Command arguments:"
  echo "  setup <id> <port>"
  IFS=$old_ifs
  exit 1
fi

[[ ! $id =~ ^[a-z0-9]*$ ]] && echoerr Invalid id. && exit 2

case $cmd in
# setup <id> <port>
'setup')
  port=$3

  [[ ! $port =~ ^[1-9][0-9]*$ ]] && echoerr Invalid port. && exit 3

  # create config file
  echo -n "Writing configuration to $confdir/tenant-$id.conf ... "
  sed "s/<id>/$id/g;s/<port>/$port/g;s/<confdir>/${confdir//\//\\/}/g" < templates/template.conf > $confdir/tenant-$id.conf
  echo OK

  # create init script
  echo -n "Creating init script $available/$id ... "
  sed "s/<id>/$id/g" < templates/template.initd > $available/$id
  chmod a+x $available/$id
  ln -s $available/$id $enabled/$id
  echo OK

  echo Running bootstrapper ...
  sudo $bootstrapper start
  ;;

'disable'*)
  echo Stopping and disabling instance $id ...
  sudo /etc/init.d/redis-enabled/$id stop && rm $enabled/$id
  ;;

'enable'*)
  echo -n "Enabling instance $id ..."
  ln -s $available/$id $enabled/$id
  echo OK

  echo Running bootstrapper ...
  sudo $bootstrapper start
  ;;

'delete'*)
  . $0 disable $1
  echo -n "Deleting instance $id ... "
  rm $available/$id
  echo OK

esac


