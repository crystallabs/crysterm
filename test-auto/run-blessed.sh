#!/bin/bash

set +x

for p in `find -maxdepth 1 -type d | tail -n +2 `; do
    if test -e "$p/main.js"; then
      echo "$p"
      mkdir -p "$p/output"
      node "$p/main.js" --test-auto 2>"$p/output/snapshot.blessed"
    fi
done
