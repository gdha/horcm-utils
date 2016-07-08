#!/bin/sh
# postinstall.sh script

# make sure the permissions are set correctly (when we upgrade from an older version)
if [[ -d /usr/local/sbin ]]; then
    chmod 755 /usr/local/sbin
fi
