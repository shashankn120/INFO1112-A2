#!/bin/bash

host=${1:-localhost}
port=${2:-1234}

test_busy(){
    outA=$(mktemp)
    echo "Client A: sending 'assignment' to $host:$port"
    ( echo assignment | nc "$host" "$port" > "$outA" 2>&1 ) &
    pidA=$!

    sleep 2
    echo "Client B (same IP): sending 'population' while A is still being handled"
    replyB=$(echo population | nc -w 5 "$host" "$port" 2>&1)
    echo "Client B got: $replyB"

    echo "Waiting for client A to finish..."
    wait $pidA
    echo "Client A got: $(cat "$outA")"
    rm -f "$outA"

    if echo "$replyB" | grep -q "busy"; then
        echo "PASS: the second request from the same client was rejected as busy"
        exit 0
    else
        echo "FAIL: client B was not rejected"
        exit 1
    fi
}

test_busy
