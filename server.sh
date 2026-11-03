#!/usr/bin/env bash

log(){
    echo "$@" >&3
}

fail(){
    echo "error: $*" >&3
    echo "error: $*"
}