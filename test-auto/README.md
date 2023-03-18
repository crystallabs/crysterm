# Automatic testing

Files in this directory perform automatic testing.

The purpose of these tests is to:

1. Be able to spot changes in code that have consequences for rendering or functionality
2. Test rendering in different terminals
3. Have a comparison with Blessed

Some tests have their .js equivalents, which allows comparing the output to Blessed.

After running both .cr and .js tests, which will each store their outputs in
corresponding language-specific files, you can use `git diff` to identify any differences
compared to previous runs, or `diff` to compare outputs/differences between the two
implementations.

To run all tests:

```
# For Crystal ones:
./run-crysterm.sh

# For Blessed ones:
git checkout https://github.com/chjj/blessed
patch -p1 < blessed.patch
./run-blessed.sh

# To compare differences to previous runs:
git diff

# To compare differences between two implementations, e.g.:
diff -u hello/output/snapshot.blessed hello/output/snapshot.crysterm
```
