#!/bin/bash
echo Running:
ps aux | grep redis | grep -v grep

echo Configuration:
ls -alF /etc/redis

echo Enabled:
ls -alF /etc/init.d/redis-enabled

echo Available:
ls -alF /etc/init.d/redis-available

echo PID:
ls -alF /var/run/redis
