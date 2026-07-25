#!/bin/sh
if [ -f /run/openshell/auth/token ]; then
    export OPENSHELL_SANDBOX_TOKEN_FILE=/run/openshell/auth/token
    export OPENSHELL_SANDBOX_TOKEN=$(cat /run/openshell/auth/token)
fi
exec /usr/local/bin/openshell-bin "$@"
