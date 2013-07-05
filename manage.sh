#!/bin/bash

# exit codes:
# 1) invalid command
# 2) invalid id
# 3) invalid port
# 4) sudo required
# 5) already installed
# 6) not installed or broken installation
# 7) instance already exists
# 8) instance not enabled

set -e

echoerr() { echo "$@" 1>&2; }
exists() { ls -U $1 &> /dev/null; }
installed() { test -x /etc/init.d/redis-landlord; }
ensureinstalled() {
  installed
  if [[ ! $? ]]; then
    echoerr Landlord not installed.
    echo "Run \"`basename \"$0\"` install\"."
    exit 6
  fi
}
instexists() { test -x /etc/init.d/redis-available/$1; }
ensureinstexists() {
  instexists $1
  if [[ ! $? ]]; then
    echoerr $id does not exist.
    echo "Run \"`basename \"$0\"` setup $id <port>\" to create."
    exit 9
  fi
}

cmds=("install" "uninstall" "setup" "disable" "enable" "delete")
cmd=$1
id=$2
available=/etc/init.d/redis-available
enabled=/etc/init.d/redis-enabled
bootstrapper=/etc/init.d/redis-tenants
confdir=/etc/redis

scriptpath="`dirname \"$0\"`"
scriptpath="`( cd \"$scriptpath\" && pwd )`/`basename \"$0\"`"

if [[ ! `whoami` == 'root' ]]; then
  echoerr This script needs to be run as a superuser.
  echo For a password-free experience, add the following
  echo to your sudoers file:
  echo
  echo %redis ALL=NOPASSWORD: $scriptpath
  exit 4
fi

if [[ ! " ${cmds[@]} " =~ " ${cmd//[^a-z]/} " ]]; then
  old_ifs=$IFS
  IFS=','
  echo "Usage: `basename \"$0\"` <command> [arg [arg]]"
  cmds="${cmds[*]}"
  echo "Commands:"
  echo "  setup <id> <port>  Sets up an instance."
  echo "  disable <id>       Disables an instance"
  echo "  enable <id>        Enables a previously disabled instance."
  echo "  delete <id>        Deletes an instance."
  echo "  install [force]    Installs init scripts and Redis"
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
  ensureinstalled
  if [[ $(instexists) ]]; then
    echoerr $id already exists.
    echo "Run \"`basename \"$0\"` enable\" to enable."
    exit 7
  fi

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
  $bootstrapper start
  ;;

'disable'*)
  ensureinstalled
  ensureinstexists $id

  if [[ ! -x "$enabled/$id" ]]; then
    echoerr $id not enabled.
    exit 8
  fi

  echo Stopping and disabling instance $id ...
  /etc/init.d/redis-enabled/$id stop && rm $enabled/$id
  ;;

'enable'*)
  ensureinstalled
  ensureinstexists $id

  echo -n "Enabling instance $id ..."
  [[ ! -x "$available/$id" ]] && ln -s $available/$id $enabled/$id
  echo OK

  echo Running bootstrapper ...
  $bootstrapper start
  ;;

'delete'*)
  ensureinstalled
  ensureinstexists $id

  ./$0 disable $id
  echo -n "Deleting instance $id ... "
  rm $available/$id
  echo OK
  ;;

'install'*)
  if [[ -x /etc/init.d/redis-landlord && $id != 'force' ]]; then
    echoerr Landlord already installed, you probably want to uninstall first.
    exit 5
  fi

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
  if exists /etc/redis/tenant-*.conf; then
    cp /etc/redis/tenant-*.conf install/backup/conf
  fi
  for file in /var/lib/redis/landlord.{aof,rdb}; do
    test -f $file && cp $file install/backup/db
  done
  if exists /var/lib/redis/tenant-*; then
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
  # chown redis:redis /etc/redis /etc/init.d/redis-{available,enabled}
  # chmod g+w /etc/redis /etc/init.d/redis-{available,enabled} /var/run/redis
  echo OK

  /etc/init.d/redis-landlord start
  ;;

'uninstall'*)
  if [[ ! -x /etc/init.d/redis-landlord ]]; then
    echoerr Landlord not installed or installation broken.
    exit 6
  fi

  if [[ $id == 'hard' ]]; then
    echo 'Removing all traces of tenancy ...'

    # stop instances
    test -x /etc/init.d/redis-landlord && /etc/init.d/redis-landlord stop
    test -x /etc/init.d/redis-tenants && /etc/init.d/redis-tenants stop

    # remove logs
    test -f /var/log/redis/landlord.log && rm /var/log/redis/landlord.log
    if exists /var/log/redis/tenant-*.log; then
      rm /var/log/redis/tenant-*.log
    fi

    # remove dbs
    for file in /var/lib/redis/landlord.{aof,rdb}; do
      test -f $file && rm $file
    done
    if exists /var/lib/redis/tenant-*; then
      rm /var/lib/redis/tenant-*
    fi

    # remove config
    test -f /etc/redis/landlord.conf && rm /etc/redis/landlord.conf && echo removed
    if exists /etc/redis/tenant-*.conf; then
      rm /etc/redis/tenant-*.conf
    fi

    echo -n 'Restoring configuration and databases ... '
    if exists install/backup/conf/*; then
      cp install/backup/conf/* /etc/redis
    fi
    if exists install/backup/db/*; then
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
  if exists install/backup/init.d/*; then
    cp install/backup/init.d/* /etc/init.d
  fi
  echo OK
  ;;

esac

