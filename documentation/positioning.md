# Positioning and sizing in Blessed

## Positioning basics / intro

For every widget, Blessed can get, set, and/or calculate its absolute and
relative position, width and height, and the amount of inner space
that is reserved for decorations (borders and padding).

For a given widget, it can also calculate what the minimum size bounding box is
(minimum box needed to accomodate all content without scrolling).

Left, top, right and bottom values are not offsets from (0,0) on the top left, but rather from their respective sides.

In other words, a widget having `top=10` and `bottom=20` won't start in row 10 and end in row 20, but will
cover the entire space from the 10th row at the top to the 20th row from the bottom.

If you want to control the widget's height directly, instead of specifying `top` and `bottom` you would
specify `top` and `height`. The same goes for `left`/`right` and `width`, of course.

Normally, position or size is specified as integer value, or is left null for auto-calculation.
However, in certain cases (listed below) it can be specified as a string containing values 'center',
'half', or 'xx%' (for a percentage of parent).

1. 'center' makes the widget 50% the size of parent and equally spaced from top and bottom or left and right (i.e. centered).
1. 'half' equals to half of parent's width or height (i.e. "50%"), without centering.
1. Using percentages works in the following way:

- If you set widget `top: 10, height: "100%"`, it will extend outside of the screen by 10 lines, since
'100%' was calculated based on entire parent, not the current position (top: 10) within it. You should
specify `height: "100%-10"` in that case.

- Similarly, if you create a widget and give it a border, then create a child widget in it with
`height: 100%`, this will make the child widget too high by two lines (for 1 line of top and 1 line of
bottom border in the parent widget). This is because percentages of parent refer to the entire size and
not the size remaining after accounting for decorations (borders and padding).
The solution is same as above, set `height: "100%-2"`.

Finally, not directly related, but important are variables called xi, xl, yi, and yl.
Those ones do correspond to reference (0,0) on the top-left of the screen.

xi...xl specifies the column range in which the widget is rendered. E.g. a widget at position `left: 10`
and `width: 50` has `xi...xl = 10...50`. yi...yl specify the same thing for row range.

Those 4 values are enough to position every widget since all widgets are based on a rectangle.

## Relative position

The following getters and setters:

- left
- top
- right
- bottom

Are convenience aliases for rleft / rtop / rright / rbottom.

These are offsets "R"elative to the parent widget (or to the screen if the widget is at top level).

### Setters

When rleft, rtop, rright or rbottom are set, the following takes place:

If the desired value is identical to the old value, the function exits.

If the desired value is not identical to the old value (which is stored in `self.position.*`),
Blessed does the following:

- If value is an integer passed as a string, casts it to int
- Emits `Move` event on self
- Calls `self.clearPos()`
- Sets `self.position.* = value` (e.g. `self.position.left = 30`)
- Returns the (possibly casted) value that was set

Note from the above that values assigned to l/t/r/b are not kept in properties
of the same name, but setting e.g. `rleft=(value)` actually saves the value to
`self.position.left`.

Thus, it is these fields in `self.position.*` that contains values directly as
specified by user (e.g. 30, "center", "30%" etc.)

See more in `lib/widgets/element.js:1369` if interested.

### Getters

Getting relative position values does not return fixed values, but rather runs a calculation
based on absolute coordinates. The code is simple:

- rleft = self.aleft - parent.aleft
- rtop = self.atop - parent.atop
- rright = self.aright - parent.aright
- rbottom = self.abottom - parent.abottom

## Size

- width
- height

### Setters

Setting `width` and `height` behaves the same as setting "r" fields:

- If value is an integer passed as a string, casts to int
- Emits `Resize` event on self
- Calls `self.clearPos()`
- Sets `self.position.* = value` (e.g. `self.position.width = "30"`)
- Returns the (possibly casted) value that was set

### Getters

When `width` or `height` are called, they run methods `_getWidth()`/`_getHeight()`.

These methods look up `self.position.width` or `.height` respectively and do one of
three things:

- If the value is an integer, they return it
- If the value is a string, it is treated as percentage of parent, and an integer value is calculated and returned. Convenience string value "half" translates to "50%".
- If the value is null, it is calculated as largest possible space

Two notes apply when the value is null:

If left or top value is 'center', then widget's size will be first set to 50% of parent and then additionally widget will render centered.

The largest possible space (width or height) is calculated while taking all restrictions into account. In other words, the calculated space
is limited by the size of parent, amount of parent's "i" values (inner thickness, explained below), and the current widget's desired left/top/right/bottom values.

Therefore, a value of null is very different from setting "100%". Setting 100% or any percentage translates to direct percentage of parent's size,
without accounting for "i" or desired left/top/right/bottom values.

## Absolute position

- aleft
- atop
- aright
- abottom

### Setters

There is no place to store the absolute and relative position separately among widget's data (in `self.position.*`).

Setting "a" values works similarly to the "r" values. Blessed just subtracts
the parent's value from the current widget's value to convert absolute to
relative, and then proceeds as if relative value was specified.

E.g. setting `atop = value` results in `value -= parent.atop`, followed by
code identical to setting `rtop`.

The only difference compared to "r" methods is that `aleft` and `atop` support
the position being specified as "center" or "xx%" (i.e. as percentages).
In those two cases, `width` and `height` of screen are consulted to produce
integer values, and then those integers are set, the same as "r" methods would do it.

### Getters

All setters are simple in comparison to getters.

To get current values, Blessed has to do some computation which depends on the values from the
widget's parent elements.

When any widget is rendered, in its variable `self.lpos` ("last pos") Blessed stores absolute coordinates
of the render. These coordinates are in essence the same as position and size in memory, since they
should match 1:1. The only exception/problem is if a widget is moved somehow and lpos values are not
updated.

But, as Blessed's author says: "However, if we can guarantee that lpos is good and up to date, it can
be more accurate than the calculated position.

If the element is being rendered, it's guaranteed that the parent will have been rendered first, in
which case we can use the parent's lpos instead of recalculating its position (since that might be
wrong because it doesn't handle content shrinkage)".

Thus, all getter functions have an optional parameter `get`, which defaults to false. When it is
false, we simply use parent widget to access its width/height, "a" values and "i" values.

When value of `get` is true, then Blessed does not use parent directly, but looks up its
lpos. It returns parent's lpos as-is if its `aleft` (and implicitly all other 'a' values) are
filled in. If they are not filled in, Blessed first produces them and then returns the lpos object
which can be used in place of the parent. It produces "a" values based on screen width/height and
xi...xl, yi...yl values that are/must be already present.

All position-related functions have `get=false`.

All these getters return values restricted by desired left/top/right/bottom values and also honor
decorations (i.e. are offset from parent by the amount of parent's "i" values).

## Inner content offsets

- ileft
- itop
- iright
- ibottom

These return the inner thickness / reduction of space on each side of the box.
For each side, it is calculated as a sum of border width (always 0 or 1) and
padding (can be any number of cells).

Important: these "i" methods do not return a *position* but rather *amount* of
decoration on respective side within the box.

- iwidth
- iheight

These two likewise do not return the inner dimensions available for content but, similarly
to the other "i" methods, they return the sums of (left and right) or (top and bottom)
decoration.

In other words, a widget with border and 2 cells of padding at top and 3 cells of
padding at bottom has `iheight` == 1 + 2 + 3 + 1 = 7.

(In Blessed border can only be 1 cell wide/high and go around all 4 sides of a widget.
Thus `iwidth`/`iheight` assume that if border is enabled, it is on both sides, i.e.
it uses a literal value of 2 for border width/height).

## Borders, padding, and shadow

A border can only be `true` or `false`. If it is `false`, there is no border around the widget.
If it is `true`, a border of certain type is drawn around all 4 sides of the widget and is always
1 cell thick.

Padding is not just true/false like border, but can be set for each of the 4 sides individually.
Method `tpadding` stands for "total padding" and returns a sum of padding on all 4 sides.

Shadow can be set on a widget. If it is set to true, it always draws shadow on the right and
bottom side of widget, in 1 cell of height and 2 cells of width for a proportional look.
It is 50% transparent and blends with the content underneath.

Border and padding render *inside* of widget's width/height, i.e. they reduce the amount of
space available for actual content.

Shadow is casted outside of those dimensions and does not affect widget's inner space.

## Widget creation and related options

When creating widgets, one can specify left/top/right/bottom/width/height separately or provide
them all inside `position` hash. If they're given separately, Blessed packs them into `position`.

One can also specify `shrink = true` on a widget. This causes widget to render in minimal
necessary box to accomodate its content.
