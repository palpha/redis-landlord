#!/bin/bash

# exit codes:
# 1) invalid command
# 2) invalid id
# 3) invalid port
# 4) sudo required

set -e

echoerr() { echo "$@" 1>&2; }
ensuresudo() {
  if [[ ! `whoami` == 'root' ]]; then
    echoerr Sudo, please.
    exit 4
  fi
}
hasfiles() { ls -U $1/* &> /dev/null; }

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
  echo "Commands:"
  echo "  setup <id> <port>  Sets up an instance."
  echo "  disable <id>       Disables an instance"
  echo "  enable <id>        Enables a previously disabled instance."
  echo "  delete <id>        Deletes an instance."
  echo "  install            Installs init scripts and Redis"
  echo "                     configuration. Use with care."
  echo "  uninstall [hard]   Uninstalls init scripts, and optionally"
  echo "                     everything else (if hard). Use with"
  echo "                     extreme care."
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

  test -x /etc/init.d/redis-landlord && /etc/init.d/redis-landlord stop
  test -x /etc/init.d/redis-tenants && /etc/init.d/redis-tenants stop

  echo -n 'Backing up existing files ... '
  for dir in install/backup{,/{init.d,conf,db}}; do
    [[ ! -d $dir ]] && mkdir $dir
  done
  for file in /etc/init.d/redis-{landlord,server-base,tenants}; do
    test -f $file && cp $file install/backup/init.d
  done
  test -f /etc/redis/landlord.conf && cp /etc/redis/landlord.conf install/backup/conf
  if ls -U /var/lib/redis/tenant-*.conf &> /dev/null; then
    cp /etc/redis/tenant-*.conf install/backup/conf
  fi
  for file in /var/lib/redis/landlord.{aof,rdb}; do
    test -f $file && cp $file install/backup/db
  done
  if ls -U /var/lib/redis/tenant-* &> /dev/null; then
    cp /var/lib/redis/tenant-* install/backup/db
  fi
  echo OK

  echo -n 'Copying init scripts ... '
  cp install/redis-{landlord,server-base,tenants} /etc/init.d
  echo OK

  echo -n 'Copying configuration ... '
  cp install/landlord.conf /etc/redis
  echo OK

  echo -n 'Setting ownership and permissions ... '
  chown root:root /etc/init.d/redis-{landlord,server-base,tenants}
  chmod a+x /etc/init.d/redis-{landlord,server-base,tenants}
  for dir in /etc/init.d/redis-{available,enabled}; do
    [[ ! -d $dir ]] && mkdir $dir
  done
  chown redis:redis /etc/init.d/redis-{available,enabled}
  chmod g+w /etc/redis /etc/init.d/redis-{available,enabled} /var/run/redis
  echo OK
  ;;

'uninstall'*)
  ensuresudo

  if [[ $id == 'hard' ]]; then
    echo -n 'Removing all traces of tenancy ... '
    test -x /etc/init.d/redis-landlord && /etc/init.d/redis-landlord stop
    test -x /etc/init.d/redis-tenants && /etc/init.d/redis-tenants stop
    test -f /var/log/redis/landlord.log && rm /var/log/redis/landlord.log
    if ls -U /var/log/redis/tenant-*.log &> /dev/null; then
      rm /var/log/redis/tenant-*.log
    fi
    for file in /var/lib/redis/landlord.{aof,rdb}; do
      test -f $file && rm $file
    done
    if ls -U /var/lib/redis/tenant-* &> /dev/null; then
      rm /var/lib/redis/tenant-*
    fi
    test -x /etc/redis/landlord.conf && rm /etc/redis/landlord.conf
    if ls -U /etc/redis/tenant-*.conf &> /dev/null; then
      rm /etc/redis/tenant-*.conf
    fi
    echo OK

    echo -n 'Restoring configuration and databases ... '
    if ls -U install/backup/conf/* &> /dev/null; then
      cp install/backup/conf/* /etc/redis
    fi
    if ls -U install/backup/db/* &> /dev/null; then
      cp install/backup/db/* /var/lib/redis
    fi
    echo OK
  else
    echo 'Leaving Redis configuration, logs and databases.'
  fi

  echo -n 'Deleting init scripts ... '
  for file in /etc/init.d/redis-{landlord,server-base,tenants}; do
    test -f $file && rm $file
  done
  for dir in /etc/init.d/redis-{available,enabled}; do
    test -d $dir && rm -rf $dir
  done
  echo OK

  echo -n 'Restoring init scripts ... '
  if hasfiles install/backup/init.d; then
    cp install/backup/init.d/* /etc/init.d
  fi
  echo OK
  ;;

esac

