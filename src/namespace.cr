module Crysterm
  # Short, project-wide alias for the "shorthand side" of an enum-valued
  # argument: a single member shorthand (`Symbol` or `String`), or a collection
  # of shorthands for `@[Flags]` enums. Used in initializer signatures as e.g.
  # `Tput::AlignFlag | Shorthands`, with the intended enum listed first.
  # See `Crystallabs::Helpers::Enums`.
  alias Shorthands = ::Crystallabs::Helpers::Enums::Shorthands

  # This file contains definitions of various Crysterm classes that are important, but not
  # big or complex enough to warrant being in individual/dedicated files.
  #
  # Initially these contents were inside `module Namespace`, which was then `include`d
  # from `class Crysterm`. However, this separation was unnecessary, and class names were
  # reported as having "Namespace" as part of their name.
  #
  # This is now a standalone file which populates the Crysterm namespace directly. The
  # content has been left here for now (instead of being moved to `src/crysterm.cr`)
  # not to overwhelm users when first checking out the project and opening that file.

  # Rendering and drawing optimization flags.
  #
  # Smart CSR: Attempt to perform CSR optimization on all possible elements,
  # and not just on full-width ones, i.e. those with uniform cells to their sides.
  # This is known to cause flickering with elements that are not full-width, but
  # it is more optimal for terminal rendering.
  #
  # Fast CSR: Enable CSR on any element within 20 columns of the screen edges on either side.
  # It is faster than smart_csr, but may cause flickering depending on what is on
  # each side of the element.
  #
  # BCE: Attempt to perform back_color_erase optimizations for terminals that support it.
  # It will also work with terminals that don't support it, but only on lines with
  # the default background color. As it stands with the current implementation,
  # it's uncertain how much terminal performance this adds at the cost of code overhead.
  @[Flags]
  enum OptimizationFlag
    FastCSR
    SmartCSR
    BCE
  end

  # Overflow behavior when rendering and drawing elements.
  enum Overflow
    Ignore        # Render without changes (part goes out of screen and is not visible)
    Hidden        # Clip children to this widget's rectangle (like CSS `overflow: hidden`), even when the widget is not scrollable
    ShrinkWidget  # Make the Widget smaller to fit
    SkipWidget    # Do not render that widget
    StopRendering # End rendering cycle (leave current and remaining widgets unrendered)
    MoveWidget    # Move widget so that it doesn't overflow, if possible (e.g. auto-completion popups)
    # TODO Check whether StopRendering / SkipWidget work OK with things like focus etc.
    # They should be skipped in focus list if they are not rendered, of course.
  end

  # Docking behavior when borders don't have the same color
  enum DockContrast
    Ignore   # Just render, colors on adjacent cells will be different
    DontDock # Do not perform docking (leave default look)
    Blend    # Blend/mix colors for as smooth a transition as possible
  end

  # States in which a widget can be
  enum WidgetState
    Normal
    Blurred # Blur
    Focused # Focus
    Hovered # Hover
    Selected
    Disabled # Does not react to keyboard input
    # XXX Does state Hidden belong here?
    # Also does 'Unmanaged' belong here, indicating that Crysterm should not be
    # doing state transitions on it?
  end

  # Class holding different styles, depending on widget state.
  class Styles
    DEFAULT = new # Default styles for all widgets

    # Returns a copy of the default style
    def self.default
      d = DEFAULT.dup
      d.normal = d.normal.dup
      d
    end

    property normal : Style = Style.new
    property blurred : Style { normal }
    property focused : Style { normal }
    property hovered : Style { normal }
    property selected : Style { normal }
    property disabled : Style { normal }

    # TODO Add each/each_entry iterators

    def initialize(@normal = @normal, @blurred = @blurred, @focused = @focused, @hovered = @hovered, @selected = @selected, @disabled = @disabled)
    end
  end

  # Mixin providing the color setter overloads shared by `Style` and `Border`.
  #
  # Both classes store colors as native `0xRRGGBB` ints (`-1` = terminal
  # default, `nil` = unset) but, for backwards compatibility, also accept
  # `"#rrggbb"`/named-color strings, which are parsed via `Colors.convert`.
  # The including class is expected to declare `@fg`/`@bg` (as `Int32?`).
  module Colorizable
    @fg : Int32?
    @bg : Int32?

    # Native numeric color (e.g. `fg: 0x40e0c0`); stored directly.
    def fg=(color : Int)
      @fg = color.to_i32
    end

    # :ditto:
    def bg=(color : Int)
      @bg = color.to_i32
    end

    # Backwards compatibility: a `"#rrggbb"` or named ("blue") color string is
    # parsed to the native int.
    def fg=(color : String)
      @fg = Colors.convert(color).to_i32
    end

    # :ditto:
    def bg=(color : String)
      @bg = Colors.convert(color).to_i32
    end

    # Clearing a color leaves it unset (no SGR sequence emitted).
    def fg=(color : Nil)
      @fg = nil
    end

    # :ditto:
    def bg=(color : Nil)
      @bg = nil
    end
  end

  # Mixin providing the per-side (left/top/right/bottom) helpers shared by
  # `Border`, `Padding` and `Shadow`. Each including class declares its own
  # `left`/`top`/`right`/`bottom` properties (the defaults differ); this module
  # supplies the logic that operates on them.
  module SidedGeometry
    # Is there anything on the left side?
    def left?
      @left > 0
    end

    # Is there anything on the top side?
    def top?
      @top > 0
    end

    # Is there anything on the right side?
    def right?
      @right > 0
    end

    # Is there anything on the bottom side?
    def bottom?
      @bottom > 0
    end

    # Is there any [amount] defined on any side?
    def any?
      (@left + @top + @right + @bottom) > 0
    end

    # Grows (`sign = 1`) or shrinks (`sign = -1`) the given position rectangle
    # by the per-side amounts.
    def adjust(pos, sign = 1)
      pos.xi += sign * @left
      pos.xl -= sign * @right
      pos.yi += sign * @top
      pos.yl -= sign * @bottom
      pos
    end
  end

  # Class for the complete style of a widget.
  class Style
    include Colorizable

    # These (and possibly others) can't default to any color since that would generate
    # color-setting sequences in the terminal. It's better to have them nilable, in which
    # case no sequences get generated and term's default is used. That's also how Blessed
    # does it.

    # Foreground color (color of font/character).
    #
    # Crysterm's native color form is a `0xRRGGBB` integer (`-1` = terminal
    # default, `nil` = "no color set", so no SGR sequence is emitted). The
    # numeric form is canonical and is stored as-is; for backwards compatibility
    # the setter still accepts `"#rrggbb"`/named-color strings, parsing them to
    # the native int via `Colors.convert`.
    getter fg : Int32?

    # Background color (color of cell). See `#fg` for the accepted forms.
    getter bg : Int32?

    # Color setters (`fg=`/`bg=`, accepting Int/String/Nil) come from
    # `Colorizable`.

    # Bold?
    property? bold : Bool = false

    # Italic?
    property? italic : Bool = false

    # Unedline?
    property? underline : Bool = false

    # Blink?
    property? blink : Bool = false

    # Inverse?
    property? inverse : Bool = false

    # Visible?
    property? visible : Bool = true

    # Alpha (inverse of transparency). Alpha 0 == full transparency, 1 == full opacity.
    property alpha : Float64?

    # Is any transparency defined?
    #
    # This function is needed because it is not possible to test just for `alpha == nil`.
    # A value of 1.0 (full opacity) also effectively means that no transparency is enabled.
    def alpha?
      @alpha.try do |a|
        return a if a != 1.0
      end
    end

    # Length in number of characters to replace TABs with
    property tab_size = 4

    # Character to replace TABs with, multiplied by tab_size
    property tab_char = " "

    # Generic char (WIP)
    property char : Char = ' '

    # Percent char (WIP)
    property pchar : Char = ' '

    # Foreground char (WIP)
    property fchar : Char = ' '

    # Background char (WIP)
    property bchar : Char = ' '

    # XXX Test/document this.
    property? fill = true

    # Should something render inside/over the border?
    # Currently used for `Widget::Scrollbar` only.
    # XXX Rename, or make more general, or otherwise unify.
    property? ignore_border : Bool = false

    # Each of the following subelements are separate and can be styled individually.
    # If any of them is not defined, it defaults to main/parent style.
    # Names of subelements could be improved over time to be more clear.

    # Keep the list sorted alphabetically.

    # Style used for alternating (even) rows when a `Widget::Table` or
    # `Widget::ListTable` has `alternate_rows` enabled — the equivalent of Qt's
    # `QAbstractItemView#alternatingRowColors`. Defaults to `cell` (and thus to
    # the main style), so it has no visible effect until styled.
    setter alternate : Style?

    def alternate
      @alternate || cell
    end

    setter bar : Style?

    def bar
      @bar || self
    end

    def border=(value)
      @border = Border.from value
    end

    # Border is always a non-nil object. "No border" is represented by a
    # `Border` whose sides are all 0 (see `Border#any?`), which renders nothing
    # and expands the widget by nothing — exactly like the old `nil` did.
    getter border : Border { Border.new 0 }

    setter cell : Style?

    def cell
      @cell || self
    end

    setter header : Style?

    def header
      @header || self
    end

    setter item : Style?

    def item
      @item || self
    end

    # Style used for the numeric/letter prefix shown before each
    # `Widget::ListBar` command (e.g. the `1` in `1:open`). Defaults to `self`.
    setter prefix : Style?

    def prefix
      @prefix || self
    end

    # Label value is used only when internally instantiating labels on widgets,
    # to be able to set their: `style: self.style.label`. Since labels are
    # widgets, everything after that is done by looking up `@_label.style....`.
    property label : Style { Style.new }

    # property label : Style? { Style.default.label.not_nil! }
    # property label : Style { self }
    # TODO I am still not sure which of the above options is best.
    # When a decision is made, the same should be applied to all other fields
    # in this class for which it applies.
    # Namely, in the current version, if a user does not specify style, a new
    # one is generated. This requires users to style both the main widget and
    # the label (and all other sub-features) separately.
    # On the other hand, if we use the other (currently commented) implementation,
    # it conveniently defaults to self, so it achieves more results out of the
    # box. However, in many cases, you actually don't want the same style as for
    # self! (For example, if self has border: true, you probably don't want
    # border: true on the label as well!

    def padding=(value)
      @padding = Padding.from value
    end

    getter padding = Padding.default

    setter scrollbar : Style?

    def scrollbar
      @scrollbar || self
    end

    # Should element drop shadow?
    def shadow=(value)
      @shadow = Shadow.from value
    end

    # :ditto:
    getter shadow = Shadow.default

    setter track : Style?

    def track
      @track || self
    end

    def initialize(
      *,
      border = nil,
      padding = nil,
      shadow = nil,
      @scrollbar = @scrollbar,
      @track = @track,
      @alternate = @alternate,
      @bar = @bar,
      @item = @item,
      @prefix = @prefix,
      @header = @header,
      @cell = @cell,
      @label = @label,
      fg = nil,
      bg = nil,
      @bold = @bold,
      @italic = @italic,
      @underline = @underline,
      @blink = @blink,
      @inverse = @inverse,
      @visible = @visible,
      alpha = nil,
      @char = @char,
      @pchar = @pchar,
      @fchar = @fchar,
      @bchar = @bchar,
      @ignore_border = @ignore_border,
    )
      # Route fg/bg through the setters so a native `0xRRGGBB` int is normalized
      # to its `#rrggbb` string (the param is unrestricted, so each call type —
      # String, Int, or Nil — resolves to the matching `fg=`/`bg=` overload).
      self.fg = fg
      self.bg = bg
      alpha.try { |v| self.alpha = self.class.alpha_from(v) }
      border.try { |v| self.border = Border.from(v) }
      padding.try { |v| self.padding = Padding.from(v) }
      shadow.try { |v| self.shadow = Shadow.from(v) }
    end

    def self.alpha_from(value : Float64 | Bool?)
      case value
      in Float
        value
      in true
        0.5
      in false
        1.0
      in nil
        nil
      end
    end
  end

  # Type of border to draw.
  enum BorderType
    Bg   # Bg color
    Line # Line, drawn in ACS or Unicode chars
    # Dotted
    # Dashed
    # Solid
    # Double
    # DotDash
    # DotDotDash
    # Groove
    # Ridge
    # Inset
    # Outset
  end

  # Class for border definition.
  class Border
    include Colorizable
    include SidedGeometry

    property type = BorderType::Line

    # Border colors. Native form is a `0xRRGGBB` int (`-1` = terminal default,
    # `nil` = unset); `"#rrggbb"`/named strings are accepted for backwards
    # compatibility and parsed via `Colors.convert`. See `Style#fg`. The setters
    # come from `Colorizable`.
    getter bg : Int32?
    getter fg : Int32?

    property char = ' '
    # XXX There is some duplication between style and these 5.
    # They must be present for sattr() to be able to work on the Border object.
    # But on the other hand, it allows these features which do not exist in Blessed.
    property? bold : Bool = false
    property? italic : Bool = false
    property? underline : Bool = false
    property? blink : Bool = false
    property? inverse : Bool = false
    property? visible : Bool = true

    property left = 1
    property top = 1
    property right = 1
    property bottom = 1

    def self.from(value)
      case value
      in true
        Border.new
      in nil, false
        Border.new 0
      in BorderType
        Border.new value
      in Border
        value
      in Int
        Border.new value, value, value, value
      end
    end

    def initialize(
      @type = @type,
      bg = nil,
      fg = nil,
      @left = @left,
      @top = @top,
      @right = @right,
      @bottom = @bottom,
    )
      # Route through the setters so a native int or a `"#rrggbb"`/named string
      # both resolve to the native int form.
      self.bg = bg unless bg.nil?
      self.fg = fg unless fg.nil?
    end

    def initialize(all : Int)
      @left = @top = @right = @bottom = all
    end

    def initialize(@left : Int, @top : Int, @right : Int, @bottom : Int)
    end

    # XXX enable these two after -Dpreview_overload_order becomes the default
    # def initialize(left_and_right, top_and_bottom)
    #  @left = @right = left_and_right
    #  @top = @bottom = top_and_bottom
    # end

    # def initialize(all : Bool = true)
    #  @left = @top = @right = @bottom = all
    # end

    # Per-side predicates (`left?`/`top?`/`right?`/`bottom?`), `any?` and
    # `adjust` come from `SidedGeometry`.
  end

  # Class for padding definition.
  #
  # NOTE "Padding" as in spacing around elements. Same order as in HTML (ltrb)
  class Padding
    include SidedGeometry

    class_property default = new 0

    property left : Int32 = 0
    property top : Int32 = 0
    property right : Int32 = 0
    property bottom : Int32 = 0

    def self.from(value)
      case value
      in true
        Padding.new 1
      in nil, false
        Padding.default
      in Padding
        value
      in Int
        Padding.new value, value, value, value
      end
    end

    def initialize(all : Int)
      @left = @top = @right = @bottom = all
    end

    def initialize(@left : Int, @top : Int, @right : Int, @bottom : Int)
    end

    # Per-side predicates, `any?` and `adjust` come from `SidedGeometry`.
  end

  # Class for shadow definition.
  class Shadow
    include SidedGeometry

    class_property default = new 0, 0, 0, 0

    # Width of shadow on the left side
    property left : Int32 = 0

    # Height of shadow on the top side
    property top : Int32 = 0

    # Width of shadow on the right side
    property right : Int32 = 2

    # Height of shadow on the bottom side
    property bottom : Int32 = 1

    # Shadow alpha value (0 == full transparency, 1 == full opacity)
    property alpha : Float64 = 0.5

    def initialize(
      @left = @left,
      @top = @top,
      @right = @right,
      @bottom = @bottom,
      @alpha = @alpha,
    )
    end

    # Parse shadow value
    def self.from(value)
      case value
      in true
        Shadow.new
      in nil, false
        Shadow.default
      in Shadow
        value
      in Float
        Shadow.new value
      end
    end

    # def initialize(all : Int)
    #  @left = @top = @right = @bottom = all
    # end

    def initialize(@alpha : Float64)
    end

    # Resolves a per-side shadow spec to a width/height: `true` means the
    # side's default extent (*on*), `false`/`nil` means none, and an explicit
    # `Int` is used verbatim.
    private def dim(value : Bool | Int32?, on : Int32) : Int32
      case value
      in true       then on
      in false, nil then 0
      in Int        then value
      end
    end

    def initialize(left : Bool | Int32?, top : Bool | Int32?, right : Bool | Int32?, bottom : Bool | Int32?, @alpha = @alpha)
      @left = dim left, 2
      @top = dim top, 1
      @right = dim right, 2
      @bottom = dim bottom, 1
    end

    # Per-side predicates and `any?` come from `SidedGeometry`.
  end

  # class FocusEffects
  #  property bg
  # end

  # class HoverEffects
  #  property bg : String = "black"
  # end

  # Used to represent minimal widget position. It is returned from methods
  # that run calculations to determine that. *i fields are start positions,
  # *l methods are end positions.
  #
  # Used only internally; could be replaced by anything else that has
  # the necessary properties.
  struct Rectangle
    getter xi : Int32
    getter xl : Int32
    getter yi : Int32
    getter yl : Int32
    getter get : Bool

    # NOTE Don't remember the exact function of `get`. IIRC it goes to
    # recalculate from parent. Check what the function is and document
    # it here.
    def initialize(@xi, @xl, @yi, @yl, @get = false)
    end
  end

  # Helper class implementing only minimal position-related interface.
  # Used for holding widget's last rendered position.
  # XXX Could be renamed to LastRenderedPos[ition] for clarity.
  class LPos
    # TODO Can almost be replaced with a struct. Only minimal problems appear.
    # See tech-demo example, fix the issue and replace with struct.

    None = new

    # Starting cell on X axis
    property xi : Int32 = 0

    # Ending cell on X axis
    property xl : Int32 = 0

    # Starting cell on Y axis
    property yi : Int32 = 0

    # Endint cell on Y axis
    property yl : Int32 = 0

    property base : Int32 = 0

    # Informs us which side is partly hidden due to being enclosed in a
    # parent (and potentially scrollable) element.
    property? no_left : Bool = false
    property? no_right : Bool = false
    property? no_top : Bool = false
    property? no_bottom : Bool = false

    # Number of times object was rendered
    property renders = 0

    property aleft : Int32? = nil
    property atop : Int32? = nil
    property aright : Int32? = nil
    property abottom : Int32? = nil
    property awidth : Int32? = nil
    property aheight : Int32? = nil

    # These should be allowed to be just 0 because I'd think their offsets
    # are already included in a* properties.
    # (XXX Verify that and fix; seems like an inconsistency in logic if that
    # sentence/description is true.
    property ileft : Int32 = 0
    property itop : Int32 = 0
    property iright : Int32 = 0
    property ibottom : Int32 = 0
    property iwidth : Int32 = 0
    property iheight : Int32 = 0

    property _scroll_bottom : Int32 = 0
    property _clean_sides : Bool = false

    def initialize(
      @xi = @xi,
      @xl = @xl,
      @yi = @yi,
      @yl = @yl,
      @base = @base,
      @no_left = @no_left,
      @no_right = @no_right,
      @no_top = @no_top,
      @no_bottom = @no_bottom,

      @renders = @renders,

      # Disable all this:
      @aleft = @aleft,
      @atop = @atop,
      @aright = @aright,
      @abottom = @abottom,
      @awidth = @awidth,
      @aheight = @aheight,

      @ileft = @ileft,
      @itop = @itop,
      @iright = @iright,
      @ibottom = @ibottom,
      @iwidth = @iwidth,
      @iheight = @iheight,
    )
    end

    # Re-initializes this instance in place to the same state a freshly
    # constructed `LPos.new(xi:, xl:, ...)` would have. Used by
    # `Widget#_get_coords` on the render hot path to reuse the widget's existing
    # `@lpos` instead of allocating a new `LPos` every widget, every frame (the
    # allocation this whole class's `# TODO ... struct` note is about).
    #
    # Besides the geometry fields passed in, this MUST reset the lazily-computed
    # cache fields (`aleft`/`atop`/.../`_clean_sides`) back to their constructor
    # defaults: they are filled on demand by `last_rendered_position`/`clean_sides`
    # and keyed to the *previous* frame's geometry, so a reused instance that kept
    # them would hand back stale absolute positions after a widget moves.
    def reset(
      @xi,
      @xl,
      @yi,
      @yl,
      @base,
      @no_left,
      @no_right,
      @no_top,
      @no_bottom,
      @renders,
    ) : self
      @aleft = nil
      @atop = nil
      @aright = nil
      @abottom = nil
      @awidth = nil
      @aheight = nil
      @ileft = 0
      @itop = 0
      @iright = 0
      @ibottom = 0
      @iwidth = 0
      @iheight = 0
      @_scroll_bottom = 0
      @_clean_sides = false
      self
    end
  end
end
