# Decorations

This document covers:

1. Borders
2. Padding
3. Shadow
4. Labels
5. Cursor

## Borders

Blessed supports borders around widgets.

Border and padding render inside the widget's width and height, rather than rendering outside of it. Consequently,
the amount of space available for content may be smaller than the set width/height.

Widget initializer has property `border` which can be just a type of border or a bigger border definition object.

If border is enabled, it is drawn around all 4 sides of the widget and is 1 cell thick.

Border has a type, which can be `bg` (default) or `line`.

If type is `bg`, border is drawn by default using black background color and ' ' (space) as filling character.
If type is `line`, then it is drawn using line-looking characters, along with properly accounting for angles and docking to other borders on the screen.

If `border` is an object, then more options can be specified:

```
  self.border = {
    type: 'bg',  # 'bg' | 'line' (or 'ascii' which is alias for 'line')
    bg: '...',   # Background color
    fg: '...',   # Foreground color
    ch: ' '      # Filling character, default is space
    bold: true/false,      # Bold the filling char
    underline: true/false, # Underline the filling char

    # Documented in more detail below:
    left: true/false,
    top: true/false,
    right: true/false,
    bottom: true/false,

    # Style (explained below)
    style: { ... }
  }
```

As seen from the above output, there have been plans for enabling border on each of 4 sides individually.
That's why we see one can specify left/top/right/bottom as true/false values.

However, that has not been developed fully because in many places Blessed's code just checks if
`border` is truthy, and if it is, assumes that border has been enabled on all 4 sides.

In addition to the definitions in the `border` property, border can also be styled via widget `#style` property.
In fact, if `border.style = {}` is defined, it is copied over to `style.border`, and the values under `border`
directly like 'bg', 'fg', etc. are also copied into `style.border`. Values left/top/right/bottom are not copied
into style, though. The idea was probably that these are structural definitions that should not be part
of style.

This shows how the idea developed over time in Blessed (style was gradually moved from `border` and `border.style`
into `style.border`).

Finally, when a widget has a scrollbar, scrollbar will normally render in the rightmost column of the
widget. When border is enabled, scrollbar will render one position inwards. However, if scrollbar has the
setting `ignoreBorder: true`, then scrollbar will render in the column occupied by the border, re-using
the border column for its functionality.

In Crysterm:

- Everything is (or will be) in `style.border`. The property `border` will not exist on widget.
- Default border type is `BorderType::Line`, not bg'

There is an incompatibility in border color. Blessed defaults to border's background color being 'black',
unless specifically overriden.

In Crysterm, everything style-related has been consolidated into `self.style`, and this is a recursive
structure -- if `style.border` is set, it will be used for the border. If it is not set, calling
`self.style.border` will fallback to `self.style`.

That's why in Crysterm border is by default drawn using the same background color as the widget, and not
black.

Additionally, in Crysterm there is `Crysterm::Style.default`. This default instance of style can be
modified and will automatically apply to all widgets that do not have style specifically overriden.
