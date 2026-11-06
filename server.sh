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


all_ips(){
    ifconfig 2>/dev/null | grep -oE 'inet (addr:)?[0-9]+(\.[0-9]+){3}' | sed 's/inet //; s/addr://'
}


get_ip(){
    all_ips | grep -v '^127\.' | head -n 1
}


listen_addrs(){
    ss -ltn 2>/dev/null | awk 'NR > 1 {print $4}'
}

wait_for(){
    until grep -q "$2" "$1" 2>/dev/null; do
        if ! kill -0 "$3" 2>/dev/null; then
            grep -q "$2" "$1" 2>/dev/null
            return
        fi
        sleep 0.05
    done
}

workDir=$(mktemp -d)
busyFlag="$workDir/busy" 

busy_listener(){

    addr=$1
    n=0
    while [ -f "$busyFlag" ]; do
        n=$((n+1))
        d="$workDir/busy-$addr-$n"
        mkdir "$d" && mkfifo "$d/in" "$d/out" && : > "$d/err"
        $ncBin -v -n -N -l "$addr" "$PORT" < "$d/out" > "$d/in" 2> "$d/err" &
        bncPid=$!
        exec 7> "$d/out"
        exec 8< "$d/in"

        #Waiting for a client or for the main request to finish
        until grep -q '^Connection received' "$d/err"; do
            [ -f "$busyFlag" ] || break
            kill -0 "$bncPid" 2>/dev/null || break
            sleep 0.1
        done

        if grep -q '^Connection received' "$d/err"; then
            line=$(grep -m1 '^Connection received' "$d/err")
            bIp=$(echo "$line" | awk '{print $4}')
            read -r -t 2 -u 8 bReq
            bReq=${bReq%$'\r'}
            owner=$(cat "$busyFlag" 2>/dev/null)
            echo "$line"
            if [ "$bIp" = "$owner" ]; then
                echo "error: server busy - your previous request from $bIp is still being processed, try again later" >&7
            else
                echo "error: server busy with another client, try again later" >&7
            fi
            exec 7>&- 8<&-
            #Giving nc enough time to flush the reply
            for _ in 1 2 3 4 5 6 7 8 9 10; do
                kill -0 "$bncPid" 2>/dev/null || break
                sleep 0.2
            done
        elif [ -f "$busyFlag" ] && ! kill -0 "$bncPid" 2>/dev/null; then
            echo "warning: busy listener on $addr could not start: $(cat "$d/err")"
            exec 7>&- 8<&-
            rm -rf "$d"
            return
        else
            exec 7>&- 8<&-
        fi
        kill "$bncPid" 2>/dev/null
        wait "$bncPid" 2>/dev/null
        rm -rf "$d"
    done
}

start_busy(){
    echo "$1" > "$busyFlag"
    busyPids=""
    for addr in $allIps; do
        busy_listener "$addr" &
        busyPids="$busyPids $!"
    done
}

stop_busy(){
    rm -f "$busyFlag"
    for pid in $busyPids; do
        wait "$pid" 2>/dev/null
    done
    busyPids=""
}

html_cells(){
    awk -v bs="$(printf '\b')" '{
        gsub("." bs, "")
        gsub(/\|/, "  ")
        gsub(/[*#]/, "")
        gsub(/\[[^]]*\]/, "  ")
        n = split($0, parts, /  +/)
        for (i = 1; i <= n; i++) {
            c = parts[i]
            gsub(/^ +| +$/, "", c)
            if (c != "" && c !~ /^[-=+_ ]+$/) print c
        }
    }' "$1"
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