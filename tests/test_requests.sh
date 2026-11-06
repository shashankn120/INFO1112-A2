#!/bin/bash

host=${1:-localhost}
port=${2:-1234}

send(){
    echo "\$ echo '$1' | nc $host $port"
    echo "$1" | nc -w 60 "$host" "$port"
    status=$?
    if [ $status -ne 0 ]; then
        echo "error: nc exited with status $status (is the server running?)"
    fi
    echo "----------------"
    sleep 1
}

send "assignment"
send "Asssignment"
echo "\$ bash tests/get_population.sh $host $port"
bash "$(dirname "$0")/get_population.sh" "$host" "$port"
echo "----------------"
sleep 1
send "poi Sydney Opera House"
send "-33.8568,151.2153"
send "poi Eiffel Tower"
send "hello"
