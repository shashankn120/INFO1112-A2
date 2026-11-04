#!/usr/bin/env bash

csvAwk='
function csvsplit(line, f,    n, i, c, field, inq) {
    n = 0; field = ""; inq = 0
    for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (inq) {
            if (c == "\"") {
                if (substr(line, i + 1, 1) == "\"") { field = field "\""; i++ }
                else inq = 0
            } else field = field c
        } else if (c == "\"") inq = 1
        else if (c == ",") { f[++n] = field; field = "" }
        else field = field c
    }
    f[++n] = field
    return n
}'

log(){
    echo "$@" >&3
}

fail(){
    echo "error: $*" >&3
    echo "error: $*"
}

case $# in
    0)run_server ;;
    1)if ! [ "$1" -ge 1 ] 2>/dev/null || [ "$1" -gt 65535 ]; then
        echo "usage: port must be a number between 1 and 65535"
        exit 1
      fi
      PORT=$1
      run_server ;;
    *)echo "usage: bash server.sh [port]"
      exit 1 ;;
esac