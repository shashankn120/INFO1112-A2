#!/bin/bash

host=${1:-localhost}
port=${2:-1234}

test_not_running(){
    echo "Sending 'assignment' to $host:$port (server.sh should NOT be running)"
    reply=$(echo assignment | nc -w 3 "$host" "$port" 2>&1)
    status=$?
    echo "nc exit status: $status"
    [ -n "$reply" ] && echo "nc output: $reply"

    if [ $status -ne 0 ]; then
        echo "PASS: nc could not connect (connection refused)"
        exit 0
    elif [ -z "$reply" ]; then
        echo "PASS: connected to Docker's port forwarder but got no reply"
        exit 0
    else
        echo "FAIL: the server answered"
        exit 1
    fi
}

test_not_running
