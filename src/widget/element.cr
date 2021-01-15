require "../aux"
require "../events"
require "./node"
require "./element/position"
require "./element/content"
require "./element/pos"
require "./element/rendering"

module Crysterm
  abstract class Element < Node
    include EventHandler
    include Element::Position
    include Element::Content
    include Element::Rendering
    include Element::Pos

    # document XXX
    property no_overflow : Bool

    # Dock borders? (See `Screen#dock_borders?` for more information)
    @dock_borders : Bool

    # Draw half-transparent shadow on the element's right and bottom?
    property shadow : Bool

    # Is element hidden? Hidden elements are not rendered on the screen and their dimensions don't use screen space.
    property? hidden = false

    # 
    private property? fixed = false

    # Horizontal text alignment
    @align = "left" # Enum or class

    # Vertical text alignment
    @valign = "top"

    # Can element's content be word-wrapped?
    property? wrap = true

    # Can width/height be auto-adjusted during rendering based on content and child elements?
    property? resizable = false

    # Element's blank/fill character for rendering.
    property ch = ' '

    # Is element clickable?
    property? clickable = false

    # Can element receive keyboard input?
    property? keyable = false

    # Is element draggable?
    property? draggable = false

    # Is element scrollable?
    property? scrollable = false

    # XXX is this bool?
    property scrollbar : Bool = false

    # XXX FIX
    # Used only for lists
    property _isList = false
    property _isLabel = false
    property interactive = false
    # XXX

    property auto_focus = false

    property position : Tput::Position

    # XXX why are these here and not in @position?
    property top = 0
    property left = 0
    setter width = 0
    property height = 0

    # Does it accept keyboard input?
    @input = false

    # Is element's content to be parsed for tags?
    property? parse_tags = true

    # Offset from the top of the scroll content.
    property child_base = 0

    property? _no_fill = false

    # Amount of padding on the inside of the element
    property padding : Padding

    # Element's border.
    property border : Border?

    def initialize(
      # These end up being part of Position.
      # If position is specified, these are ignored.
      left = nil,
      top = nil,
      right = nil,
      bottom = nil,
      width = nil,
      height = nil,

      @hidden = false,
      @fixed = false,
      @wrap = true,
      @align = "left",
      @valign = "top",
      position : Tput::Position? = nil,
      @resizable = false,
      @no_overflow = true,
      @dock_borders = true,
      @shadow = false,
      style : Style? = nil,
      padding : Int32 | Padding = 0,
      border = nil,
      # @clickable=false,
      content = "",
      label = nil,
      hover_text = nil,
      # hover_bg=nil,
      @draggable = false,
      focused = false,

      # synonyms
      @parse_tags = true,

      auto_focus = false,

      **node
    )
      super **node

      if position
        @position = position
      else
        @position = Tput::Position.new \
          left: left,
          top: top,
          right: right,
          bottom: bottom,
          width: width,
          height: height
      end
      @resizable = true if @position.resizable?

      if style
        @style = style
      else
        @style = Style.new # defaults are in the class initializer
      end

      case padding
      when Int
        @padding = Padding.new padding
      when Padding
        @padding = padding
      else
        raise "Invalid padding argument"
      end

      @border = case border
                when true
                  Border.new BorderType::Line
                when nil
                  # Nothing
                when BorderType
                  Border.new border
                when Border
                  border
                else
                  raise "Invalid border argument"
                end

      set_content(content, true)
      set_label(label) if label
      set_hover(hover_text) if hover_text

      # on(AddHandlerEvent) { |wrapper| }
      on(ResizeEvent) { parse_content }
      on(AttachEvent) { parse_content }
      # on(DetachEvent) { @lpos = nil }

      # Style related stuff ...

      focus if focused
    end

    def set_label(label)
    end

    def remove_label
    end

    def set_hover(hover_text)
    end

    def remove_hover
    end

    def hide
      return if @hidden
      clear_pos
      @hidden = true
      emit HideEvent
      #@screen.rewind_focus if focused?
      @screen.rewind_focus if @screen.focused == self
    end

    def show
      return unless @hidden
      @hidden = false
      emit ShowEvent
    end

    def toggle_visibility
      @hidden ? show : hide
    end

    def focus
      @screen.focused = self
    end

    def focused?
      @screen.focused == self
    end

    def _align(line, width, align)
      #return line unless align

      cline = line.gsub /\x1b\[[\d;]*m/, ""
      len = cline.size
      s = @resizable ? 0 : width - len

      return line if len == 0
      return line if s < 0

      if align == "center"
        s = " " * (s//2)
        return s + line + s
      elsif align == "right"
        s = " " * s
        return s + line
      elsif @parse_tags && line.index /\{|\}/
        parts = line.split /\{|\}/
        cparts = cline.split /\{|\}/
        s = Math.max(width - cparts[0].size - cparts[1].size, 0)
        s = " " * s
        "#{parts[0]}#{s}#{parts[1]}"
      end

      line
    end

    def visible?
      el = self
      while el
        return false if el.detached?
        return false if el.hidden?
        el = el.parent
      end
      true
    end

    def _detached?
      el = self
      while el
        return false if el.is_a? Screen
        return true if !el.parent
        el = el.parent
      end
      false
    end

    def draggable?
      @_draggable
    end

    def draggable=(draggable : Bool)
      draggable ? enable_drag(draggable) : disable_drag
    end

    def enable_drag(x)
      @_draggable = true
    end

    def disable_drag
      @_draggable = false
    end

    def set_index(index)
      return unless parent = @parent
      if index < 0
        index = parent.children.size + index
      end

      index = Math.max index, 0
      index = Math.min index, parent.children.size - 1

      i = parent.children.index self
      return unless i

      parent.children.insert index, parent.children.delete_at i
      nil
    end

    def front!
      set_index -1
    end

    def back!
      set_index 0
    end

    def self.sattr(style, fg = nil, bg = nil)
      # See why this can be nil
      style = style.not_nil!

      if fg.nil? && bg.nil?
        fg = style.fg
        bg = style.bg
      end

      # Support style.* being Procs

      ((style.invisible ? 16 : 0) << 18) |
        ((style.inverse ? 8 : 0) << 18) |
        ((style.blink ? 4 : 0) << 18) |
        ((style.underline ? 2 : 0) << 18) |
        ((style.bold ? 1 : 0) << 18) |
        (Colors.convert(fg) << 9) |
        Colors.convert(bg)
    end

    def sattr(style, fg = nil, bg = nil)
      self.class.sattr style, fg, bg
    end

    def free
      # Remove all listeners
    end

    def screenshot(xi = nil, xl = nil, yi = nil, yl = nil)
      xi = @lpos.xi + ileft + (xi || 0)
      if xl
        xl = @lpos.xi + ileft + (xl || 0)
      else
        xl = @lpos.xl - iright
      end

      yi = @lpos.yi + itop + (yi || 0)
      if yl
        yl = @lpos.yi + itop + (yl || 0)
      else
        yl = @lpos.yl - ibottom
      end

      @screen.screenshot xi, xl, yi, yl
    end

    def _update_cursor(arg)
    end
  end
end
