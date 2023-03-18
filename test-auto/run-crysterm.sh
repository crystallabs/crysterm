#!/bin/bash

set +x

for p in `find -maxdepth 1 -type d | tail -n +2 `; do
    if test -e "$p/main.cr"; then
      echo "$p"
      mkdir -p "$p/output"
      crystal run "$p/main.cr" -- --test-auto 2>"$p/output/screenshot.crysterm"
    fi
done
