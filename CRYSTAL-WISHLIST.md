# Wishlist for Crystal:


## Loops to support labels, using whatever syntax would be appropriate, e.g.:

```
outer: while true
  while true
    break :outer
  end
end
```

## Indirect initialization. This to work without throwing error:

```
class X
  @x : Bool

  def initialize
    set_vars
  end

  def set_vars
    @x = true
  end
end
```

## Introducing 'undefined' or similar to mean unspecified values. E.g.:

```
class X
  @var = "test"

  def initialize(@var = undefined)
    puts @var
  end

end

X.new # ==> "test"
```

## Type-safe `#==` operator:

Due to default implementation of `#==` in `Value` and `Reference`, comparing
anything to anything is allowed and returns false. This is very dangerous
and leads to incorrect/invalid comparisons which always fail.

https://github.com/crystal-lang/crystal/issues/10277

https://github.com/crystal-ameba/ameba/issues/237

## API to expose a method to kill Fiber from outside code.

## Ability to create a Proc and partial from a method with named args:

```
def f(a : Int32, b : Int32)
end

# Can't use named args at the moment:
pf = ->f(a : Int32, b : Int32)

# Nor this:
ppf = pf.partial(b: 10)

```

Exists partly as https://github.com/crystal-lang/crystal/issues/11099

## Better subclassing in Procs:

```
class A; end
class B < A; end

# This works:
arr = [] of A
arr << B.new

# But with Procs it doesn't:
arr2 = [] of Proc(A, Nil)
arr2 << ->(e : B) { }
```
