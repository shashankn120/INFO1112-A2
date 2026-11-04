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

setup_deps(){
    missing=""
    command -v curl >/dev/null 2>&1 || missing="$missing curl"
    command -v jq >/dev/null 2>&1 || missing="$missing jq"
    command -v html2text >/dev/null 2>&1 || missing="$missing html2text"
    command -v ss >/dev/null 2>&1 || missing="$missing iproute2"
    command -v ifconfig >/dev/null 2>&1 || missing="$missing net-tools"
    nc -h 2>&1 | grep -q OpenBSD || missing="$missing netcat-openbsd"

    if [ -n "$missing" ]; then
        if command -v apk >/dev/null 2>&1; then
            echo "Installing missing packages:$missing"
            for pkg in $missing; do
                apk add --no-cache "$pkg" >/dev/null 2>&1 
            done
            command -v ss >/dev/null 2>&1 || apk add --no-cache iproute2-ss >/dev/null 2>&1
        fi
    fi

    for tool in curl jq html2text; do
        command -v $tool >/dev/null 2>&1 
    done

    if ! python3 -c 'import matplotlib' >/dev/null 2>&1; then
        if command -v apk >/dev/null 2>&1; then
            echo "Installing python3 py3-matplotlib (for population.png)"
            apk add --no-cache python3 py3-matplotlib >/dev/null 2>&1 
        fi
        python3 -c 'import matplotlib' >/dev/null 2>&1 
    fi
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