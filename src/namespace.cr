module Crysterm
  # Module holding the general namespace for Crysterm
  module Namespace
    Widget = ::Crysterm::Widget

    # Rendering and drawing optimization flags.
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

      property tab_size = TAB_SIZE

      # NOTE: Eventually reduce/streamline these
      property char : Char = ' '  # Generic char
      property pchar : Char = ' ' # Percent char
      property fchar : Char = ' ' # Foreground char
      property bchar : Char = ' ' # Bg char
      # property fchar : Char = ' '

      # For scrollbar
      property? ignore_border : Bool

      # Each of these are separate subelements that can be styled.
      # If any of them is not defined, it defaults to main/parent style.
      setter border : Style?
      setter scrollbar : Style?
      setter shadow : Style?
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

      def shadow
        @shadow || self
      end

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
        @shadow = nil,
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

    class Border
      property type = BorderType::Line
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

    class FocusEffects
      property bg
    end

    class HoverEffects
      property bg : String = "black"
    end
  end
end
