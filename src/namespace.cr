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
      Bg   # Bg color
      Fg   # Fg color
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

    # Type of layout to use in a `Layout`.
    enum LayoutType
      Inline # Masonry-like
      Grid   # Table-like
    end

    # Overflow behavior when rendering and drawing elements.
    enum Overflow
      Ignore        # Render without changes (part goes out of screen and is not visible)
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

    # Class for the complete style of a widget.
    class Style
      class_property default = new # Default style for all widgets

      property fg : String = "white"
      property bg : String = "black"
      property bold : Bool = false
      property underline : Bool = false
      property blink : Bool = false
      property inverse : Bool = false
      property invisible : Bool = false
      property transparency : Float64? = nil
      property shadow_transparency : Float64 = 0.5

      property tab_size = 4

      # NOTE: Eventually reduce/streamline these
      property char : Char = ' '  # Generic char
      property pchar : Char = ' ' # Percent char
      property fchar : Char = ' ' # Foreground char
      property bchar : Char = ' ' # Bg char

      property? fill = true

      property? ignore_border : Bool = false # If true, it's rendered in place of the border

      # Each of the following subelements are separate and can be styled individually.
      # If any of them is not defined, it defaults to main/parent style.
      # Keep the list sorted alphabetically.
      # Names of subelements could be improved over time to be more clear.

      setter bar : Style?

      def bar
        @bar || self
      end

      setter blur : Style?

      def blur
        @blur || self
      end

      setter border : Style?

      def border
        @border || self
      end

      setter cell : Style?

      def cell
        @cell || self
      end

      setter focus : Style?

      def focus
        @focus || self
      end

      setter header : Style?

      def header
        @header || self
      end

      setter hover : Style?

      def hover
        @hover || self
      end

      setter item : Style?

      def item
        @item || self
      end

      setter label : Style?

      def label
        @label || self
      end

      setter scrollbar : Style?

      def scrollbar
        @scrollbar || self
      end

      setter selected : Style?

      def selected
        @selected || self
      end

      setter track : Style?

      def track
        @track || self
      end

      # setter shadow : Style?

      # def shadow
      #  @shadow || self
      # end

      def initialize(
        *,
        @border = @border,
        @scrollbar = @scrollbar,
        @focus = @focus,
        @hover = @hover,
        # @shadow = nil,
        @track = @track,
        @bar = @bar,
        @selected = @selected,
        @item = @item,
        @header = @header,
        @cell = @cell,
        @label = @label,
        @fg = @fg,
        @bg = @bg,
        @bold = @bold,
        @underline = @underline,
        @blink = @blink,
        @inverse = @inverse,
        @invisible = @invisible,
        transparency = nil,
        @char = @char,
        @pchar = @pchar,
        @fchar = @fchar,
        @bchar = @bchar,
        @ignore_border = @ignore_border
      )
        transparency.try { |v| @transparency = v.is_a?(Bool) ? (v ? 0.5 : nil) : v }
      end
    end

    # Class for padding definition.
    #
    # NOTE "Padding" as in spacing around elements. Same order as in HTML (ltrb)
    class Padding
      property left : Int32 = 0
      property top : Int32 = 0
      property right : Int32 = 0
      property bottom : Int32 = 0

      def initialize(all)
        @left = @top = @right = @bottom = all
      end

      def initialize(@left = @left, @top = @top, @right = @right, @bottom = @bottom)
      end

      def any?
        (@left + @top + @right + @bottom) > 0
      end
    end

    # Class for border definition.
    class Border
      property type = BorderType::Line
      # NOTE These don't have ? because they'll be replaced with Ints in the future,
      # specifying corresponding border thicknesses
      property left : Bool = true
      property top : Bool = true
      property right : Bool = true
      property bottom : Bool = true

      def initialize(
        @type = @type,
        @left = @left,
        @top = @top,
        @right = @right,
        @bottom = @bottom
      )
      end

      # XXX enable these two after -Dpreview_overload_order becomes the default
      #def initialize(left_and_right, top_and_bottom)
      #  @left = @right = left_and_right
      #  @top = @bottom = top_and_bottom
      #end

      #def initialize(all : Bool = true)
      #  @left = @top = @right = @bottom = all
      #end

      def any?
        !!(@left || @top || @right || @bottom)
      end
    end

    # Class for shadow definition.
    class Shadow
      # property type = BorderType::Line
      # NOTE These don't have ? because they'll be replaced with Ints in the future,
      # specifying corresponding border thicknesses
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
