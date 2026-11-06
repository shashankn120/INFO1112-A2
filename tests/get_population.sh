#!/bin/bash

host=${1:-localhost}
port=${2:-1234}

get_population(){
    echo "Sending 'population' to $host:$port"
    if ! echo population | nc -w 60 "$host" "$port" > population.png; then
        echo "error: could not connect to $host:$port "
        rm -f population.png
        exit 1
    fi
    if [ "$(head -c 4 population.png | tail -c 3)" = "PNG" ]; then
        echo "Saved population.png ($(wc -c < population.png) bytes)"
        exit 0
    fi
    # not a PNG -> the server sent a text error
    if [ -s population.png ]; then
        cat population.png
    else
        echo "error: empty reply from the server"
    fi
    rm -f population.png
    exit 1
}

get_population
