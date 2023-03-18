# Automatic testing

Files in this directory perform automatic testing.

The purpose of these tests is to:

1. Be able to spot changes in code that have consequences for rendering or functionality
2. Test rendering in different terminals
3. Have a comparison with Blessed

Some tests have their .js equivalents, which allows comparing the output to Blessed.

Run `./run-crysterm.sh` to run all crysterm tests.

Run `./run-blessed.sh` to run all crysterm tests. For this to work you will need to
checkout blessed from Git:

```
cd crysterm
git checkout https://github.com/chjj/blessed
```

Then you can use `git diff` to identify differences compared to previous runs, or you
can run diffs between Crysterm and Blessed versions.
