module Crysterm
  # Module holding the general namespace for Crysterm
  module Namespace
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

    # Type of border to draw.
    enum BorderType
      Bg
      Fg
      Line
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

    # Type of layout to use in a `Layout`.
    enum LayoutType
      Inline # Masonry-like
      Grid   # Table-like
    end

    # Overflow behavior when rendering and drawing elements.
    enum Overflow
      Ignore        # Render without changes
      ShrinkWidget  # Make the Widget smaller to fit
      SkipWidget    # Do not render the widget
      StopRendering # End rendering cycle (leave current and remaining widgets unrendered)
      MoveWidget    # Move so that it doesn't overflow if possible (e.g. auto-completion popups)
      # XXX Check whether StopRendering / SkipWidget work OK with things like focus etc.
      # They should be skipped, of course, if they are not rendered.
    end

    # Docking behavior when borders don't have the same color
    enum DockContrast
      Ignore
      DontDock
      Blend
    end

    # Class for the complete style of a widget.
    class Style
      # Potentially make all subelements be filled in here,
      # and if they're a new Style class have it know its
      # Style parent. This way we could default values to
      # the parent value.
      property fg : String = "white"
      property bg : String = "black"
      property bold : Bool = false
      property underline : Bool = false
      property blink : Bool = false
      property inverse : Bool = false
      property invisible : Bool = false
      property transparency : Float64? = nil
      property shadow_transparency : Float64 = 0.5

      property tab_size = TAB_SIZE

      # NOTE: Eventually reduce/streamline these
      property char : Char = ' '  # Generic char
      property pchar : Char = ' ' # Percent char
      property fchar : Char = ' ' # Foreground char
      property bchar : Char = ' ' # Bg char
      # property fchar : Char = ' '

      property? fill = true

      # For scrollbar
      property? ignore_border : Bool

      # Each of these are separate subelements that can be styled.
      # If any of them is not defined, it defaults to main/parent style.
      setter border : Style?
      setter scrollbar : Style?
      # setter shadow : Style?
      setter track : Style?
      setter bar : Style?
      setter item : Style?
      setter header : Style?
      setter cell : Style?
      setter label : Style?

      setter blur : Style?
      setter focus : Style?
      setter hover : Style?
      setter selected : Style?

      def border
        @border || self
      end

      def scrollbar
        @scrollbar || self
      end

      def focus
        @focus || self
      end

      def hover
        @hover || self
      end

      # def shadow
      #  @shadow || self
      # end

      def track
        @track || self
      end

      def bar
        @bar || self
      end

      def selected
        @selected || self
      end

      def item
        @item || self
      end

      def header
        @header || self
      end

      def cell
        @cell || self
      end

      def label
        @label || self
      end

      def blur
        @blur || self
      end

      def initialize(
        @border = nil,
        @scrollbar = nil,
        @focus = nil,
        @hover = nil,
        # @shadow = nil,
        @track = nil,
        @bar = nil,
        @selected = nil,
        @item = nil,
        @header = nil,
        @cell = nil,
        @label = nil,
        fg = nil,
        bg = nil,
        bold = nil,
        underline = nil,
        blink = nil,
        inverse = nil,
        invisible = nil,
        transparency = nil,
        char = nil,
        pchar = nil,
        fchar = nil,
        bchar = nil,
        ignore_border = nil
      )
        fg.try { |v| @fg = v }
        bg.try { |v| @bg = v }
        bold.try { |v| @bold = v }
        underline.try { |v| @underline = v }
        blink.try { |v| @blink = v }
        inverse.try { |v| @inverse = v }
        invisible.try { |v| @invisible = v }
        transparency.try { |v| @transparency = v.is_a?(Bool) ? (v ? 0.5 : nil) : v }
        char.try { |v| @char = v }
        pchar.try { |v| @pchar = v }
        fchar.try { |v| @fchar = v }
        bchar.try { |v| @bchar = v }
        ignore_border.try { |v| @ignore_border = v }
      end
    end

    # Class for padding definition.
    #
    # NOTE "Padding" as in spacing around elements.
    class Padding
      property left : Int32
      property top : Int32
      property right : Int32
      property bottom : Int32

      def initialize(all)
        @left = @top = @right = @bottom = all
      end

      def initialize(@left = 0, @top = 0, @right = 0, @bottom = 0)
      end

      def any?
        (@left + @top + @right + @bottom) > 0
      end
    end

    # Class for border definition.
    class Border
      property type = BorderType::Line
      # These don't have ? because they'll be replaced with Ints in the future
      property left : Bool
      property top : Bool
      property right : Bool
      property bottom : Bool

      def initialize(
        @type = BorderType::Line,
        @left = true,
        @top = true,
        @right = true,
        @bottom = true
      )
      end

      def any?
        !!(@left || @top || @right || @bottom)
      end
    end

    # Class for shadow definition.
    class Shadow
      # property type = BorderType::Line
      property? left : Bool
      property? top : Bool
      property? right : Bool
      property? bottom : Bool

      def initialize(
        # @type = BorderType::Line,
        @left,
        @top,
        @right,
        @bottom = true
      )
      end

      def initialize(left_and_right, top_and_bottom)
        @left = @right = left_and_right
        @top = @bottom = top_and_bottom
      end

      def initialize(all)
        @left = @top = @right = @bottom = all
      end

      def initialize
        @left = @top = false
        @right = @bottom = true
      end

      def any?
        !!(@left || @top || @right || @bottom)
      end
    end

    # class FocusEffects
    #  property bg
    # end

    # class HoverEffects
    #  property bg : String = "black"
    # end

    # Used to represent minimal widget dimensions, after running method(s)
    # to determine them.
    #
    # Used only internally; could be replaced by anything else that has
    # the necessary properties.
    struct Rectangle
      getter xi : Int32
      getter xl : Int32
      getter yi : Int32
      getter yl : Int32
      getter get : Bool

      def initialize(@xi, @xl, @yi, @yl, @get = false)
      end
    end

    # Helper class implementing only minimal position-related interface.
    # Used for holding widget's last rendered position.
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
      property ileft : Int32 = 0
      property itop : Int32 = 0
      property iright : Int32 = 0
      property ibottom : Int32 = 0
      property iwidth : Int32 = 0
      property iheight : Int32 = 0

      property _scroll_bottom : Int32 = 0
      property _clean_sides : Bool = false

      def initialize(
        @xi = 0,
        @xl = 0,
        @yi = 0,
        @yl = 0,
        @base = 0,
        @no_left = false,
        @no_right = false,
        @no_top = false,
        @no_bottom = false,
        @renders = 0,

        # Disable all this:
        @aleft = nil,
        @atop = nil,
        @aright = nil,
        @abottom = nil,
        @awidth = nil,
        @aheight = nil,

        @ileft = 0,
        @itop = 0,
        @iright = 0,
        @ibottom = 0,
        @iwidth = 0,
        @iheight = 0
      )
      end
    end
  end
end
