# Wishlist for Crystal:


## Loops to support labels, using whatever syntax would be appropriate, e.g.:

```cr
outer: while true
  while true
    break label: :outer
  end
end
```

I know that it _is_ possible to make any code work without break that supports labels.
But in some cases, the code is much more complex to write and follow in that way.
Also, it forces the user to separate the code for "break" and "jump" into two
places, which is unintuitive and the two locations are not always conveniently close
to each other.

## Indirect initialization. This to work without throwing an error:

```cr
class X
  @x : Bool

  def initialize
    set_vars
  end

  def set_vars
    @x = true
  end
end

X.new
```

This wouldn't necessarily have to support full indirect initialization. It
would be enough that, if some methods are always/unconditionally called from `initialize`,
the same checks that apply to `initialize` also apply to those methods, and to consider
`@x` to be set.

## (Partly resolved) Using 'undefined' to expand into property's default value

```cr
class X
  @var = "test"

  def initialize(@var = undefined)
    puts @var
  end

end

X.new # ==> "test"
```

This functionality appears to exist in a limited form.
There is not a macro or keyword named `undefined`, but one can repeat the variable name:

```
  def initialize(@var = @var)
    puts @var # ==> "test"
  end
```

However, it seems to work in `initialize` only, not in `new`.

Thanks to @Blacksmoke16 for discussion / tip.

A larger topic by Blacksmoke, relevant/related to this, is https://forum.crystal-lang.org/t/rfc-undefined-type/2695.

## (Resolved) Method overloads to not get overwritten by each other so easily:

This currently doesn't work because the first overload gets completely overwritten:

```cr
def bar(a = 0, b = 0, c = 0, d = 0)
end

def bar
end

bar(a: 1)
```

It results in:

```
In :7:1

 7 | bar(a: 1)
     ^--
Error: no argument named 'a'

Matches are:
 - bar()
 ```

@Sija created a ticket based on my initial report:

https://github.com/crystal-lang/crystal/issues/10231

The issue has since been resolved by @HertzDevil, but is not yet the default.
To have the fix applied, you must invoke crystal with `crystal run -Dpreview_overload_order ...`.

## Type-safe `#==` operator:

Due to default implementation of `#==` in `Value` and `Reference`, comparing
anything to anything is allowed and returns false. This is very dangerous
and leads to incorrect/invalid comparisons which always fail.

https://github.com/crystal-lang/crystal/issues/10277

Since it is probably too late to make this change in the language, the only
thing that was possible to do was to add support to Ameba that Sija did:

https://github.com/crystal-ameba/ameba/issues/237

However, it only does literal-to-literal comparison checking and thus
does not help the issue very much.

The proper solution would be to have this supported at the language level in Crystal 3.0.
For example, to have an operator like `#==?` that behaves like the current `#==` (i.e. returns false if
arguments are not comparable). And then to change `#==` to a type-safe version so that it produces an
error when there is no comparison defined between its arguments.

@straight-shoota added this item (although with a different proposed solution) to the wishlist
for the next Crystal major version (TODO: find a reference to it).

## API to expose a method to kill Fiber from outside code.

This supposedly exists in non-public API, but I did not find it, be it public
or not.

## Ability to create a Proc and partial from a method with named args:

```cr
def f(a : Int32, b : Int32)
end

# Can't use named args at the moment:
pf = ->f(a : Int32, b : Int32)

# Nor this:
ppf = pf.partial(b: 10)

```

A workaround was developed by @HertzDevil in https://github.com/crystal-lang/crystal/issues/11099

## Better subclassing in Procs:

```cr
class A; end
class B < A; end

# This works:
arr = [] of A
arr << B.new

# But with Procs it doesn't:
arr2 = [] of Proc(A, Nil)
arr2 << ->(e : B) { }
```
