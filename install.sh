#!/bin/bash

set -e

echo -n 'Copying init scripts ... '
cp install/redis-server /etc/init.d
cp install/redis-server-base /etc/init.d
cp install/redis-tenants /etc/init.d
echo OK
echo ''

echo -n 'Copying configuration ... '
cp install/redis.conf /etc/redis
echo OK
echo ''

echo -n 'Setting ownership and permissions ... '
chown root:root /etc/init.d/redis-server /etc/init.d/redis-server-base /etc/init.d/redis-tenants
chmod a+x /etc/init.d/redis-server /etc/init.d/redis-server-base /etc/init.d/redis-tenants
mkdir /etc/init.d/redis-available
mkdir /etc/init.d/redis-enabled
chown redis:redis /etc/init.d/redis-available /etc/init.d/redis-enable
chmod g+w /etc/redis /etc/init.d/redis-available /etc/init.d/redis-enabled /var/run/redis
echo OK
echo ''
