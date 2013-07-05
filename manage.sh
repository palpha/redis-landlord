#!/bin/bash

# exit codes:
# 1) invalid command
# 2) invalid id
# 3) invalid port
# 4) sudo required

set -e

echoerr() { echo "$@" 1>&2; }
ensuresudo() { [[ ! `whoami` == 'root' ]] && echoerr Sudo, please. && exit 4 }

cmds=("install" "uninstall" "setup" "disable" "enable" "delete")
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
  sed "s/<id>/$id/g;s/<port>/$port/g;s/<confdir>/${confdir//\//\\/}/g" < templates/conf > $confdir/tenant-$id.conf
  echo OK

  # create init script
  echo -n "Creating init script $available/$id ... "
  sed "s/<id>/$id/g" < templates/initd > $available/$id
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
  . $0 disable $id
  echo -n "Deleting instance $id ... "
  rm $available/$id
  echo OK
  ;;

'install'*)
  ensuresudo

  /etc/init.d/redis-server stop
  test -x /etc/init.d/redis-tenants && /etc/init.d/redis-tenants stop

  echo -n 'Backing up existing files ... '
  mkdir install/backup/{init.d,conf,db}
  cp /etc/init.d/redis-{server{,-base},tenants} install/backup/init.d
  cp /etc/redis/redis.conf install/backup/conf
  cp /etc/redis/tenant-*.conf install/backup/conf
  cp /var/lib/redis/main.{aof,rdb} install/backup/db
  cp /var/lib/redis/tenant-*.{aof,rdb} install/backup/db

  echo -n 'Copying init scripts ... '
  cp install/redis-{server{,-base},tenants} /etc/init.d
  echo "OK\n"

  echo -n 'Copying configuration ... '
  cp install/redis.conf /etc/redis
  echo "OK\n"

  echo -n 'Setting ownership and permissions ... '
  chown root:root /etc/init.d/redis-{server{,-base},tenants}
  chmod a+x /etc/init.d/redis-{server{,-base},tenants}
  mkdir /etc/init.d/redis-{available,enabled}
  chown redis:redis /etc/init.d/redis-{available,enabled}
  chmod g+w /etc/redis /etc/init.d/redis-{available,enabled} /var/run/redis
  echo "OK\n"
  ;;

'uninstall'*)
  ensuresudo

  case "$id" in
  'hard'*)
    echo -n 'Removing all traces of tenancy ... '
    /etc/init.d/redis-tenants stop
    /etc/init.d/redis-server stop
    rm /var/log/redis/main.log
    rm /var/log/redis/tenant-*.log
    rm /var/lib/redis/main.{aof,rdb}
    rm /var/lib/redis/tenant-*.{aof,rdb}
    rm /etc/redis/redis.conf
    rm /etc/redis/tenant-*.conf
    echo "OK\n"

    echo -n 'Restoring configuration and databases ... '
    cp install/backup/conf/* /etc/redis
    cp install/backup/db/* /var/lib/redis
    ;;

  *)
    echo 'Leaving Redis configuration, logs and databases.'
    ;;

  esac

  echo -n 'Deleting init scripts ... '
  rm /etc/init.d/redis-{server{,-base},tenants}
  echo "OK\n"

  echo -n 'Restoring init scripts ... '
  cp install/backup/init.d/* /etc/init.d
  echo "OK\n"
  ;;

esac

