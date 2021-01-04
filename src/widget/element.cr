require "../aux"
require "../events"
require "./node"
require "./element/position"
require "./element/content"
require "./element/pos"

module Crysterm
  module Widget
    class Element < Node
      include EventHandler
      include Element::Position
      include Element::Content
      include Element::Rendering
      include Element::Pos

      @type = :element
      @name : String

      @no_overflow : Bool
      @dock_borders : Bool
      @shadow : Bool
      property? hidden = false
      property? fixed = false
      @align = :left # Enum or class
      @valign = :top
      property? wrap = false # XXX change to true
      property shrink = false # XXX add ?
      property ch = ' '

      property? clickable = false
      property? keyable = false
      property? draggable = false
      property? scrollable = false

      # XXX is this bool?
      property scrollbar : Bool = false

      # XXX shat
      # Used only for lists
      property _isList = false
      property _isLabel = false
      property interactive = false
      # XXX shat

      property position : Tput::Position

      property top=0
      property left=0
      property width=0
      property height=0

      # Does it accept keyboard input?
      @input = false

      @parse_tags = false

      property border : Tput::Border? = nil
      property child_base = 0

      property content = ""

      property _pcontent : String?

      property? _no_fill = false

      property padding : Tput::Padding

      def initialize(
        @name,

        # These end up being part of Position.
        # If position is specified, these are ignored.
        left=0,
        top=0,
        right=0,
        bottom=0,
        width=0,
        height=0,

        @hidden=false,
        @fixed=false,
        @wrap=false, # XXX change to true later
        @align= :left,
        @valign = :top,
        position : Tput::Position? = nil,
        @shrink=false,
        @no_overflow=true,
        @dock_borders=true,
        @shadow=false,
        # TODO - style
        style : Style? = nil,
        padding : Int32 | Tput::Padding = 0,
        border : Tput::BorderType | Tput::Border | Nil = nil,
        #@clickable=false,
        content=nil,
        label=nil,
        hover_text=nil,
        #hover_bg=nil,
        @draggable=false,
        focused=false,

        # synonyms
        parse_tags=false, # XXX change to true later
        tags=false,
      )
        super()

        if position
          @position = position
        else
          @position = Tput::Position.new \
            left: left,
            top: top,
            right: right,
            bottom: bottom,
            width: width || 0,
            height: height || 0
        end
        @shrink = true if @position.shrink?

        if style
          @style = style
        else
          @style = Style.new # defaults are in the class initializer
        end

        case padding
        when Int
          @padding = Tput::Padding.new padding, padding, padding, padding
        when Tput::Padding
          @padding = padding
        else
          raise "Invalid padding argument"
        end

        case border
        when Tput::BorderType
          @border = Tput::Border.new type: border
        when Tput::Border
          @border = border
        end
        # Add border style to style # TODO

        set_content(content, true) if content
        set_label(label) if label
        set_hover(hover_text) if hover_text

        @parse_tags = parse_tags || tags

        #on(AddHandlerEvent) { |wrapper| }

        on(ResizeEvent) { parse_content }
        on(AttachEvent) { parse_content }
        #on(DetachEvent) { @lpos = nil }

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

      def set_effects()
      end

      def focused?
        @screen.focused == self
      end

      def hide
        return if @hidden
        clear_pos
        @hidden = true
        emit HideEvent
        @screen.try &.rewind_focus if focused?
      end

      def show
        return unless @hidden
        @hidden=false
        emit ShowEvent
      end

      def toggle
        @hidden ? show : hide
      end

      def focus
        @screen.focused = self
      end

      def _align(line, width, align)
        return line unless align

        cline = line.gsub /\x1b\[[\d;]*m/, ""
        len = cline.size
        s = @shrink ? 0 : width - len

        return line if len == 0
        return line if s < 0

        if align == "center"
          s = " " * (((s//2))+1)
          return s + line + s
        elsif align == "right"
          s = " " * (s+1)
          return s + line
        elsif @parse_tags && line.index /\{|\}/
          parts = line.split /\{|\}/
          cparts = cline.split /\{|\}/
          s = Math.max(width - cparts[0].size - cparts[1].size, 0)
          s = " " * s # XXX s+1 ?
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
          return false if el.type == :screen
          return true if !el.parent
          el = el.parent
        end
        false
      end

      def draggable?
        @_draggable == true
      end
      def draggable=(draggable : Bool)
        draggable ? enable_drag(draggable) : disable_drag
      end
      def enable_drag(x)
      end
      def disable_drag
      end

      def index=(index)
        return unless parent = @parent
        if index<0
          index = parent.children.size + index
        end

        index = Math.max index, 0
        index = Math.min index, parent.children.size - 1

        i = parent.children.index self
        return unless i

        parent.children.insert index, parent.children.delete_at i

      end
      def front!
        self.index= -1
      end
      def back!
        self.index= 0
      end

      def sattr(style, fg=nil, bg=nil

        # TODO see why this can be nil
        style = style.not_nil!

        if fg.nil? && bg.nil?
          fg = style.fg
          bg = style.bg
        end

        # Support style.* being Procs

        ((style.invisible ? 16 : 0) << 18) |
        ((style.inverse ? 8 : 0) << 18)    |
        ((style.blink ? 4 : 0) << 18)      |
        ((style.underline ? 2 : 0) << 18)  |
        ((style.bold ? 1 : 0) << 18)       #|
        #(colors.convert(fg) << 9)    |
        #colors.convert(bg)
      end

      def free
        # Remove all listeners
      end

      def screenshot(xi=nil,xl=nil,yi=nil,yl=nil)
        xi = @lpos.xi + @ileft + (xi||0)
        if xl
          xl = @lpos.xi + @ileft + (xl||0)
        else
          xl = @lpos.xl - @iright
        end

        yi = @lpos.yi + @itop + (yi||0)
        if yl
          yl = @lpos.yi + @itop + (yl||0)
        else
          yl = @lpos.yl - @ibottom
        end

        @screen.screenshot xi, xl, yi, yl
      end

    end
  end
end
