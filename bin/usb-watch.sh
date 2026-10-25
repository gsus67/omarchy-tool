#!/bin/bash

# Cheap probe the panel runs every couple of seconds while "Periféricos en
# Windows" is on (no jq, no config reads): prints the QEMU pid of the running
# Omarchy Windows VM (empty if none) and whether Windows asked, through
# "Devolver periféricos a Linux", to give everything back.
#
#   usb-watch.sh <request-file>   ->   pid=<n> request=<0|1>

pid=$(pgrep -f '^qemu-system-x86_64 .*monitor unix:/run/shm/monitor.sock' | head -n1)
request=0
[[ -n ${1:-} && -e $1 ]] && request=1
echo "pid=$pid request=$request"
