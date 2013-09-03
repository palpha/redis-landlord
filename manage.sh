#!/bin/bash

# To do:
#   thread safety
#   handle redis-landlord downtime

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

prefix=${LANDLORD_PREFIX}
initd=${LANDLORD_INITD_DIR:-$prefix/etc/init.d}
confdir=${LANDLORD_ETC_DIR:-$prefix/etc/redis}
dbdir=${LANDLORD_DB_DIR:-$prefix/var/lib/redis}
logdir=${LANDLORD_LOG_DIR:-$prefix/var/log/redis}
rundir=${LANDLORD_RUN_DIR:-$prefix/var/run/redis}
pidfile=${LANDLORD_PID_FILE:-redis-landlord.pid}
pidpath=$rundir/$pidfile
landlordport=${LANDLORD_PORT:-6380}

isinstalled=([ -x $initd/redis-landlord ])

cmds=("install" "uninstall" "setup" "disable" "enable" "delete")
cmd=$1
id=$2
available=$initd/redis-available
enabled=$initd/redis-enabled
bootstrapper=$initd/redis-tenants

scriptpath="`dirname \"$0\"`"
scriptpath="`( cd \"$scriptpath\" && pwd )`/`basename \"$0\"`"

echoerr() { echo "$@" 1>&2; }
exists() { ls -U $1 &> /dev/null; }
ensureinstalled() {
  if ! $isinstalled; then
    echoerr Landlord not installed.
    echo "Run \"`basename \"$0\"` install\"."
    exit 6
  fi
}

ensureinstexists() {
  if [[ ! -x "$available/$1" ]]; then
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
  echo ""
  echo "If landlord should use a non-standard port, set LANDLORD_PORT. Eg:"
  echo "  env LANDLORD_PORT=5678 `basename \"$0\"` install"
  IFS=$old_ifs
  exit 1
fi

validateid() {
  re="^[-_a-zA-Z0-9]*$"
  if [[ ! $id =~ $re || $id == "" ]]; then
    echoerr 'Invalid id.'
    exit 2
  fi
}

cleanup() {
    echo -n "Cleaning up ... "
    $enabled/$id stop
    rm $confdir/tenant-$id.conf
    rm $enabled/$id
    rm $available/$id
    echo OK
}

case "$cmd" in
# setup <id> <port>
setup)
  ensureinstalled
  validateid
  isavailable=([ -x "$available/$id" ])
  isenabled=([ -x "$enabled/$id" ])
  if $isenabled; then
    echoerr $id already exists.
    exit 7
  elif $isavailable; then
    echoerr $id already exists, but is disabled.
    echo "Run \"`basename \"$0\"` enable\" to enable."
    exit 8
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
  $enabled/$id start

  echo -n 'Pinging new instance ... '
  sleep 1

  set +e
  pinginst $id $port
  if [[ $? ]]; then
    echo OK
    echo -n 'Adding to landlord database ... '
    if [[ `echo -e "SET landlord:tenant:$id:port $port\nSADD landlord:tenants $id" | redis-cli -a landlord -p $landlordport > /dev/null` ]]; then
      echo OK

      echo Log says:
      tail -1 $logdir/tenant-$id.log
    else
      echo NOT OK
      cleanup
    fi
  else
    echo NOT OK
    cleanup
  fi
  
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
  $enabled/$id stop && rm $enabled/$id
  ;;

enable)
  ensureinstalled
  validateid
  ensureinstexists $id

  echo -n "Enabling instance $id ..."
  [[ ! -x "$enabled/$id" ]] && ln -s $available/$id $enabled/$id
  echo OK

  echo Running bootstrapper ...
  $enabled/$id start

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
  port=`redis-cli -a landlord -p $landlordport GET landlord:tenant:$id:port`
  if [[ $port != "" ]]; then
    echo -e "SREM landlord:ports:occupied $port" | redis-cli -a landlord -p $landlordport > /dev/null
  fi
  echo -e "DEL landlord:tenant:$id:port\nSREM landlord:tenants $id" | redis-cli -a landlord -p $landlordport > /dev/null
  echo OK
  ;;

install)
  if $isinstalled && [[ $id != 'force' ]]; then
    echoerr Landlord already installed, you probably want to uninstall first.
    exit 5
  fi

  [[ -x $initd/redis-landlord ]] && $initd/redis-landlord stop
  [[ -x $initd/redis-tenants ]] && $initd/redis-tenants stop

  echo -n 'Backing up existing files ... '

  # prep backup dirs
  for dir in install/backup{,/{init.d,conf,db}}; do
    [[ ! -d $dir ]] && mkdir $dir
  done

  # init scripts
  for file in $initd/redis-{landlord,server-base,tenants}; do
    [[ -f $file ]] && cp $file install/backup/init.d
  done

  # config
  [[ -f $confdir/landlord.conf ]] && cp $confdir/landlord.conf install/backup/conf
  exists $confdir/tenant-*.conf && cp $confdir/tenant-*.conf install/backup/conf

  # databases
  for file in $dbdir/landlord.{aof,rdb}; do
    test -f $file && cp $file install/backup/db
  done
  exists $dbdir/tenant-* && cp $dbdir/tenant-* install/backup/db

  echo OK

  if [[ ! -d $confdir ]]; then
    mkdir -p $confdir
    chown redis:redis $confdir
  fi

  if [[ ! -d $dbdir ]]; then
    mkdir -p $dbdir
    chown redis:redis $dbdir
  fi

  if [[ ! -d $logdir ]]; then
    mkdir -p $logdir
    chown redis:redis $logdir
  fi

  [[ -d $initd ]] || mkdir -p $initd

  echo -n 'Writing init scripts ... '
  sed "s/<initd>/${initd//\//\\/}/g;s/<confdir>/${confdir//\//\\/}/g;s/<pidfile>/${pidfile}/g" < install/redis-landlord > $initd/redis-landlord
  sed "s/<rundir>/${rundir//\//\\/}/g" < install/redis-server-base > $initd/redis-server-base
  sed "s/<initd>/${initd//\//\\/}/g" < install/redis-tenants > $initd/redis-tenants
  echo OK

  echo -n 'Writing configuration ... '
  sed "s/<port>/$landlordport/g;s/<logdir>/${logdir//\//\\/}/g;s/<dbdir>/${dbdir//\//\\/}/g;s/<pidpath>/${pidpath//\//\\/}/g" < install/landlord.conf > $confdir/landlord.conf
  echo OK

  echo -n 'Setting ownership and permissions ... '
  chown root:root $initd/redis-{landlord,server-base,tenants}
  chmod a+x $initd/redis-{landlord,server-base,tenants}
  [[ ! -d $available ]] && mkdir $available
  [[ ! -d $enabled ]] && mkdir $enabled 

  echo OK

  echo -n 'Adding landlord to boot sequence ... '
  update-rc.d redis-landlord defaults
  update-rc.d redis-tenants defaults
  echo OK

  echo Starting landlord ...
  $initd/redis-landlord start

  echo -n 'Pinging landlord instance ... '
  set +e
  pinginst landlord $landlordport
  if [[ $? ]]; then
   echo OK
  else
   echo NOT OK
  fi

  echo Log says:
  tail -1 $logdir/landlord.log

  ;;

uninstall)

  if [[ $id == 'hard' ]]; then
    echo 'Removing all traces of tenancy ...'

    # remove from boot
    test -x $initd/redis-landlord && update-rc.d redis-landlord remove
    test -x $initd/redis-tenants && update-rc.d redis-tenants remove

    # stop instances
    test -x $initd/redis-landlord && $initd/redis-landlord stop
    test -x $initd/redis-tenants && $initd/redis-tenants stop

    # remove logs
    test -f $logdir/landlord.log && rm $logdir/landlord.log
    if exists $logdir/tenant-*.log; then
      rm $logdir/tenant-*.log
    fi

    # remove dbs
    for file in $dbdir/landlord.{aof,rdb}; do
      test -f $file && rm $file
    done
    if exists $dbdir/tenant-*; then
      rm $dbdir/tenant-*
    fi

    # remove config
    test -f $confdir/landlord.conf && rm $confdir/landlord.conf && echo removed
    if exists $confdir/tenant-*.conf; then
      rm $confdir/tenant-*.conf
    fi

    echo -n 'Restoring configuration and databases ... '
    if exists install/backup/conf/*; then
      cp install/backup/conf/* $confdir
    fi
    if exists install/backup/db/*; then
      cp install/backup/db/* $dbdir
    fi
    echo OK
  elif [[ ! -x $initd/redis-landlord ]]; then
    echoerr Landlord not installed or installation broken.
    exit 6
  else
    echo 'Leaving Redis configuration, logs and databases.'

    echo 'Stopping tenants and landlord ...'
    test -x $initd/redis-landlord && $initd/redis-landlord stop
    test -x $initd/redis-tenants && $initd/redis-tenants stop
    echo 'OK'
  fi

  echo -n 'Deleting init scripts ... '
  for file in $initd/redis-{landlord,server-base,tenants}; do
    test -f $file && rm $file
  done

  test -d $available && rm -rf $available
  test -d $enabled && rm -rf $enabled

  echo OK

  echo -n 'Restoring init scripts ... '
  if exists install/backup/init.d/*; then
    cp install/backup/init.d/* $initd
  fi
  echo OK
  ;;

esac

