#!/bin/bash
echo Backups
echo =======
ls install/backup/*
echo

echo Running
echo =======
ps aux | grep redis | grep -v grep
echo

echo Init scripts
echo ============
ls -alF /etc/init.d/redis-*
echo

echo Configuration
echo =============
ls -alF /etc/redis
echo

echo Enabled
echo =======
ls -alF /etc/init.d/redis-enabled
echo

echo Available
echo =========
ls -alF /etc/init.d/redis-available
echo

echo PID files
echo =========
ls -alF /var/run/redis
echo

echo Database dumps
echo ==============
ls -alF /var/lib/redis
