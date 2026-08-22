# Crysterm application template

A minimal, copy-runnable skeleton for a new Crysterm application: a proper
`shard.yml` that depends on the released `crysterm` shard, and a `src/main.cr`
showing a window, a couple of widgets, a click handler and a key handler.

## Use it

```sh
cp -r examples/template ~/myapp        # or copy from a clone of this repo
cd ~/myapp
# Edit shard.yml: set your app's name (in both `name:` and `targets:`),
# author, and license.
shards install
crystal run src/main.cr                # run it
shards build --release                 # or build ./bin/myapp
```

Unlike the other examples in this repository (which `require` Crysterm by
relative path so they run from the source tree), this template uses
`require "crysterm"` and works anywhere.

## Where next

- [GETTING-STARTED.md](../../GETTING-STARTED.md) — a chapter-by-chapter
  tutorial that starts from exactly this kind of program.
- The other directories under [examples/](../) are complete applications,
  intended to be copied and reused the same way — just change their
  `require "../../src/crysterm"` line to `require "crysterm"` and drop the
  file into a skeleton like this one.
- Crysterm's [README](../../README.md) is the feature tour, including the
  `shard.override.yml` recipe for tracking development versions.
