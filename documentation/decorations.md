# Decorations

This document covers:

1. Borders
2. Padding
3. Shadow
4. Labels
5. Cursor
6. Styles

## Borders

Blessed supports borders around widgets.

Border and padding render inside the widget's width and height, rather rendering outside of it. Consequently,
the amount of space available for content may be smaller than the set width/height.

Widget initializer has a property named `border` which can be just a type of border or a bigger border definition object.

If border is enabled, it is drawn around all 4 sides of the widget and is 1 cell thick.

Border has a type, which can be `bg` (default) or `line`.

If type is `bg`, border is drawn by default using black background color and ' ' (space) as filling character.
If type is `line`, then it is drawn using line-looking characters, along with properly accounting for angles and docking to other borders on the screen.

When `border` is an object, as mentioned more options can be specified:

```
  self.border = {
    type: 'bg',  # 'bg' | 'line' (or 'ascii' which is alias for 'line')
    bg: '...',   # Background color
    fg: '...',   # Foreground color
    ch: ' '      # Filling character, default is space (in case of type == 'bg')

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

Attributes 'bold' and 'underline' are documented in README as possible to apply to borders, but this doesn't
seem like it was implemented.

Finally, when a widget has a scrollbar, scrollbar will normally render in the rightmost column of the
widget. When border is enabled, scrollbar will render one position inwards. However, if scrollbar has the
setting `ignoreBorder: true`, then scrollbar will render in the column occupied by the border, re-using
the border column for its functionality.

In Crysterm:

Everything is in `Widget#style.border`. The property `border` does not exist on widget.

Default border type is `BorderType::Line`, not 'bg'.

Border can be applied to each 4 sides individually (although see TODO.md for border-related issues).

Border can have thickness greater than 1. Currently this renders the same as padding does (i.e. the
border is rendered just in the outermost cells.) In the future this could be improved, so that the
border repeats in all cells that make up the border. (See how this would interoperate with option
`dock_borders`, because repeating a border over more cells would probably get detected as something
where docking would be performed.)

Additionally, in Crysterm there is `Crysterm::Style.default`. This default instance of style can be
modified and will automatically apply to all widgets that do not have style specifically overridden.

## Padding

Blessed supports padding - certain amount of empty space that will be reserved on the inside of the widget.

Same as for borders, the property does not exist on widget, but is in `Widget#style.padding`.

Same as for borders, defining padding reduces the amount of space available for content.

Padding can be specified for all 4 sides individually.

Padding's specification has an advantage that was supported per-side definitions from day 1, so it
doesn't suffer from the same bug that borders have with value 0. (Possibly the solution for the border
bug will be to make it work more like padding does.)

In Blessed there is function `tpadding()` which returns whether the widget has any padding (for
knowing whether to go into padding-related code or not). In Crysterm, this check is done with
just `if Widget#padding`.

## Shadow

Blessed supports simple widget shadow which can be enabled or disabled.

If enabled, it creates an effect of a light source from top-left, dropping shadow to the
bottom-right of the widget.

The shadow is always 1 cell high, 2 cells wide (for proportional look) and 50% transparent.

In Crysterm, shadow can be placed on all 4 sides individually, each side can have its own
depth of shadow, and the amount of shadow transparency/alpha can be controlled.

Also, the light effect is not always top-left to bottom-right, but intuitively changes
automatically, depending on which shadows are enabled.

## Labels

Labels are widgets that can be added to the first line of the widget, left or right.

They are an equivalent of panel or frame labels/titles in some other GUI toolkits.

An interesting aspect of labels in Crysterm is that they can be added to any widget.

Also, in the majority of cases labels are specified as text, and internally Blessed creates
a text box widget for them. But, in theory, any widget can be used (just some API changes
are necessary at the moment to support that comfortably).

If label is created via text (for which a box is internally created), that widget can
be managed by user afterwards. It is in property `_label` (as mentioned, the API will change).

Labels attach certain to certain events on the parent, so that they can recalculate
and redraw as necessary (for example, if they are on the right of the widget, they need to
travel as widget gets resized).

This functionality exists and will remain in Crysterm, but the API will be improved.

## Cursor

## Styles

Blessed's support for widget styles is a bit of a mess. Here's how it works in Crysterm.

The idea is that just about everything that is style-related should live in `Widget#style`
and be modifiable from there.

Based on that, the whole style/theme for an app could be specified in one Styles
object, which is serializable to file using whatever format (JSON, YAML, ...).
Saving/loading or formal theme specification has not been implemented yet.

Every widget has `style : Style` property. But, a widget can be in different states (e.g.
normal, focused, selected, blurred, etc.)

Therefore another property `styles : Styles` contains all those possible styles, and
Crysterm's code automatically points `style` to the style that is currently active.

Modifying `style` is possible, but since it's just a pointer into one of `styles` states,
modifying it actually modifies the definition of that state.

There is one state, `normal`, which is always defined (`normal = Style.new`). All other
states can be nil, and if they're not defined they default to `normal`.

In addition to various states, widgets also have various subelements. For example, in a
widget, one could want to separately style it's label, border, scrollbar, etc.

These sub-elements exist as properties inside the current style. For example,
`style.border.bg` gives the background color of the border.

Same as for styles, all subelements' styles are nilable, and if they're not defined
they default to the main style.
