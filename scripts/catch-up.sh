#!/usr/bin/env bash
# Bring a lab machine to the start of Lab NN by running the explicit
# lab01-catch-up.sh .. lab(NN-1)-catch-up.sh scripts.
#
# Usage:
#   ~/intermediate-devops-companion/scripts/catch-up.sh 04   # runs lab01..lab03 catch-up (ready to start Lab 04)
#
# You can also run any individual lab catch-up script directly:
#   ~/intermediate-devops-companion/scripts/lab01-catch-up.sh
#   ~/intermediate-devops-companion/scripts/lab02-catch-up.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target=$((10#${1:?usage: catch-up.sh NN   (the number of the lab you want to start, e.g. 02..09)}))

if [ "$target" -le 1 ]; then
  echo "Nothing to replay before Lab 01."
  echo "To complete Lab 01 itself, run: $SCRIPT_DIR/lab01-catch-up.sh"
  exit 0
fi

prev=$(printf "%02d" $((target - 1)))
script="$SCRIPT_DIR/lab${prev}-catch-up.sh"

if [ ! -x "$script" ]; then
  echo "Error: Catch-up script not found: $script" >&2
  exit 1
fi

echo "Catching up through Lab $prev so you are ready to start Lab $(printf "%02d" "$target")..."
exec "$script"
