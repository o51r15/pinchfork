#!/usr/bin/env bash

# This script is a wrapper for other programs
# that ensures they are killed when stdin closes
# (eg: a job terminates)

# Job control puts the program in its own process group, so it can be killed
# together with everything it started. yt-dlp is a PyInstaller binary: the process
# we start is only a bootloader, and the real yt-dlp (and any ffmpeg) are its
# children. Killing just the bootloader left those running on their own.
set -m

# Start the program in the background
exec "$@" &
pid1=$!

# Silence warnings from here on
exec >/dev/null 2>&1

# Read from stdin in the background and
# kill the running program's whole process group when stdin closes
exec 0<&0 $(
  while read; do :; done
  kill -KILL -- -$pid1 || kill -KILL $pid1
) &
pid2=$!

# Clean up
wait $pid1
ret=$?
kill -KILL $pid2
exit $ret
