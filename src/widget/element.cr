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
      @hidden = false
      @fixed = false
      @align = :left # Enum or class
      @valign = :top
      @wrap = true
      @shrink = false
      @ch = " "

      property? clickable = false
      property? keyable = false
      property? draggable = false
      property? scrollable = false

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

      #@parse_tags = true

      property border = Tput::Border.new
      property child_base = 0

      property content = ""

      property _pcontent : String?

      property? _no_fill = false

      def initialize(
        @name,
        top=0,
        left=0,
        width=0,
        height=0,
        tags=nil,
        @position=Tput::Position.new,
        @shrink=true,
        @no_overflow=true,
        @dock_borders=true,
        @shadow=true,
        #@style=Style.new,
        @padding = ::Tput::Padding.new, # Move out of tput XXX
        ##@border=
        #@clickable=false,
        content="",
        label=nil,
        hover_text=nil,
        #hover_bg=nil,
        @draggable=false,
        focused=false
      )
        super()

        @content = "" # XXX SHIT
        set_content(content) if content
        set_label(label) if label
        set_hover(hover_text) if hover_text

        #on(AddHandlerEvent) { |wrapper| }

        #on(ResizeEvent) { parse_content }
        #on(AttachEvent) { parse_content }
        ##on(DettachEvent) { @lpos = nil }

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
        #emit HideEvent
        @screen.try &.rewind_focus if focused?
      end

      def show
        return unless @hidden
        @hidden=false
        #emit ShowEvent
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

        case align
        when "center"
          s = " " * (((s//2))+1)
          return s + line + s
        when "right"
          s = " " * (s+1)
        else
          raise "TODO"
        end

        line
      end

      def visible?
        el = self
        while el
          return false if el.detached
          return false if el.hidden
          el = el.parent
        end 
        true
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

      def _detached?
        el = self
        while el
          return false if el.type == :screen
          return true if !el.parent
          el = el.parent
        end
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

      def sattr(style, fg, bg)
        if fg.nil? && bg.nil?
          fg = style.fg
          bg = style.bg
        end

        #if style.bold? bold()
        #,,,

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

    end
  end
end
