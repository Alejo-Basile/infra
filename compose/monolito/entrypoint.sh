#!/bin/sh
set -e
export MONGO_PASS=$(cat /run/secrets/mongo_app_password)
exec /entrypoint.sh "$@"
