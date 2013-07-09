#!/bin/bash

# To do:
#   update-rc.d
#   thread safety
#   PubSub instead of HTTP

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

isinstalled=([ -x /etc/init.d/redis-landlord ])

echoerr() { echo "$@" 1>&2; }
exists() { ls -U $1 &> /dev/null; }
ensureinstalled() {
  if [[ ! $isinstalled ]]; then
    echoerr Landlord not installed.
    echo "Run \"`basename \"$0\"` install\"."
    exit 6
  fi
}

ensureinstexists() {
  if [[ ! -x "/etc/init.d/redis-available/$1" ]]; then
    echoerr $id does not exist.
    echo "Run \"`basename \"$0\"` setup $id <port>\" to create."
    exit 9
  fi
}

pinginst() {
  i=0
  while :
  do
    if [[ "`redis-cli -a $1 -p $2 ping`" == 'PONG' ]]; then
      return 0
    fi

    let i++
    if [[ $i -gt 50 ]]; then
      return 1
    fi

    sleep 0.1
  done
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

validateid() {
  if [[ ! $id =~ ^[a-z0-9]*$ || $id == "" ]]; then
    echoerr 'Invalid id.'
    exit 2
  fi
}

case "$cmd" in
# setup <id> <port>
setup)
  ensureinstalled
  validateid
  if [[ -x "/etc/init.d/redis-available/$id" ]]; then
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

  echo -n 'Pinging new instance ... '
  sleep 1

  set +e
  pinginst $id $port
  if [[ $? ]]; then
    echo OK
    echo -e "SET landlord:tenant:$id:port $port\nSADD landlord:tenants $id" | redis-cli -a landlord -p 6380 > /dev/null
  else
    echo NOT OK
    echo -n "Cleaning up ... "
    rm $confdir/tenant-$id.conf
    rm $enabled/$id
    rm $available/$id
  fi

  echo Log says:
  tail -1 /var/log/redis/tenant-$id.log
  
  ;;

disable)
  ensureinstalled
  validateid
  ensureinstexists $id

  if [[ ! -x "$enabled/$id" ]]; then
    echoerr $id not enabled.
    exit 8
  fi

  echo Stopping and disabling instance $id ...
  /etc/init.d/redis-enabled/$id stop && rm $enabled/$id
  ;;

enable)
  ensureinstalled
  validateid
  ensureinstexists $id

  echo -n "Enabling instance $id ..."
  [[ ! -x "$available/$id" ]] && ln -s $available/$id $enabled/$id
  echo OK

  echo Running bootstrapper ...
  $bootstrapper start

  echo "$id enabled."
  ;;

delete)
  ensureinstalled
  validateid
  ensureinstexists $id

  set +e
  $0 disable $id
  set -e
  echo -n "Deleting instance $id ... "
  rm $available/$id
  echo -e "DEL landlord:tenant:$id:port\nSREM landlord:tenants $id" | redis-cli -a landlord -p 6380 > /dev/null
  echo OK
  ;;

install)
  if $isinstalled && [[ $id != 'force' ]]; then
    echoerr Landlord already installed, you probably want to uninstall first.
    exit 5
  fi

  [[ -x /etc/init.d/redis-landlord ]] && /etc/init.d/redis-landlord stop
  [[ -x /etc/init.d/redis-tenants ]] && /etc/init.d/redis-tenants stop

  echo -n 'Backing up existing files ... '

  # prep backup dirs
  for dir in install/backup{,/{init.d,conf,db}}; do
    [[ ! -d $dir ]] && mkdir $dir
  done

  # init scripts
  for file in /etc/init.d/redis-{landlord,server-base,tenants}; do
    [[ -f $file ]] && cp $file install/backup/init.d
  done

  # config
  [[ -f /etc/redis/landlord.conf ]] && cp /etc/redis/landlord.conf install/backup/conf
  exists /etc/redis/tenant-*.conf && cp /etc/redis/tenant-*.conf install/backup/conf

  # databases
  for file in /var/lib/redis/landlord.{aof,rdb}; do
    test -f $file && cp $file install/backup/db
  done
  exists /var/lib/redis/tenant-* && cp /var/lib/redis/tenant-* install/backup/db

  echo OK

  echo -n 'Writing init scripts ... '
  cp install/redis-{landlord,server-base,tenants} /etc/init.d
  echo OK

  echo -n 'Writing configuration ... '
  cp install/landlord.conf /etc/redis
  echo OK

  echo -n 'Setting ownership and permissions ... '
  chown root:root /etc/init.d/redis-{landlord,server-base,tenants}
  chmod a+x /etc/init.d/redis-{landlord,server-base,tenants}
  for dir in /etc/init.d/redis-{available,enabled}; do
    [[ ! -d $dir ]] && mkdir $dir
  done
  echo OK

  echo Starting landlord ...
  /etc/init.d/redis-landlord start

  echo -n 'Pinging landlord instance ... '
  set +e
  pinginst
  [[ ! $? ]] && echo NOT OK || echo OK

  echo Log says:
  tail -1 /var/log/redis/landlord.log

  ;;

uninstall)
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
  elif [[ ! -x /etc/init.d/redis-landlord ]]; then
    echoerr Landlord not installed or installation broken.
    exit 6
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

