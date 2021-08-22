require "./event"
require "./helpers"

require "./mixin/children"
require "./mixin/pos"
require "./mixin/uid"

require "./widget_rectangles"
require "./widget_content"
require "./widget_rendering"
require "./widget_position"
require "./widget_scrolling"
require "./widget_z_index"
require "./widget_hierarchy"
require "./widget_style"
require "./widget_interaction"
require "./widget_label"
require "./widget_focus"
require "./widget_visibility"

module Crysterm
  class Widget < ::Crysterm::Object
    include Mixin::Children
    include Mixin::Pos
    include Mixin::Uid

    # Arbitrary widget name
    property name : String?

    # Automatically position child elements with border and padding in mind.
    property auto_padding = true

    # Draw shadow?
    # If yes, the amount of shadow transparency can be set in `#style.shadow_transparency`.
    property shadow : Shadow?

    # XXX FIX by removing at some point
    # Used only for lists
    property _is_list = false

    # Amount of padding on the inside of the element
    property padding : Padding

    # Widget's border.
    property border : Border?

    # Storage for any miscellaneous data.
    property data : JSON::Any?

    # Gets set to true after `#destroy` has been invoked.
    property? destroyed = false

    # WIP
    property left : Int32 | String | Nil
    property top : Int32 | String | Nil
    property right : Int32 | Nil
    property bottom : Int32 | Nil
    property width : Int32 | String | Nil
    property height : Int32 | String | Nil
    property? resizable = false

    def initialize(
      @parent = nil,
      *,

      @left = nil,
      @top = nil,
      @right = nil,
      @bottom = nil,
      @width = nil,
      @height = nil,

      hidden = nil,
      @fixed = false,
      @wrap = true,
      @align = Tput::AlignFlag::Top | Tput::AlignFlag::Left,
      resizable = nil,
      overflow : Overflow? = nil,
      @style = Style.new, # Previously: Style? = nil
      padding : Padding | Int32 = 0,
      border = nil,
      shadow = nil,
      # @clickable=false,
      content = "",
      label = nil,
      hover_text = nil,
      scrollable = nil,
      # hover_bg=nil,
      @draggable = false,
      focused = false,

      @parse_tags = false,

      auto_focus = false,

      scrollbar = nil,
      track = nil,

      @name = nil,
      @screen = determine_screen, # NOTE a todo item about this is in file TODO
      index = -1,
      children = [] of Widget,
      @auto_padding = true,
      tabc = nil,
      @keys = false,
      input = nil
    )
      hidden.try { |v| @hidden = v }

      resizable.try { |v| @resizable = v }

      overflow.try { |v| @overflow = v }

      scrollbar.try { |v| @scrollbar = v }
      track.try { |v| @track = v }
      scrollable.try { |v| @scrollable = v }

      @tabc = tabc || (" " * @style.tab_size)
      input.try { |v| @input = v }

      @uid = next_uid

      # Allow name to be nil, to avoid creating strings
      # @name = name || "#{self.class.name}-#{@uid}"

      # $ = _ = JSON/YAML::Any

      case padding
      when Int
        @padding = Padding.new padding, padding, padding, padding
      when Padding
        @padding = padding
      else
        raise "Invalid padding argument"
      end

      @border = case border
                when true
                  Border.new BorderType::Line
                when nil, false
                  # Nothing
                when BorderType
                  Border.new border
                when Border
                  border
                else
                  raise "Invalid border argument"
                end

      @shadow = case shadow
                when true
                  Shadow.new
                when nil, false
                  # Nothing
                when Shadow
                  shadow
                else
                  raise "Invalid shadow argument"
                end

      # Add element to parent
      if parent = @parent
        parent.append self
        # elsif screen # XXX Don't do; see above for arg screen, and see TODO file
        #  screen.try &.append self
      end

      children.each do |child|
        append child
      end

      set_content(content, true)
      set_label(label, "left") if label
      set_hover(hover_text) if hover_text

      # on(AddHandlerEvent) { |wrapper| }
      on(Crysterm::Event::Resize) { parse_content }
      on(Crysterm::Event::Attach) { parse_content }
      # on(Crysterm::Event::Detach) { @lpos = nil } # XXX D O or E O?

      if s = scrollbar
        # Allow controlling of the scrollbar via the mouse:
        # TODO
        # if @mouse
        #  # TODO
        # end
      end

      # # TODO same as above
      # if @mouse
      # end

      if @keys && !@ignore_keys
        on(Crysterm::Event::KeyPress) do |e|
          key = e.key
          ch = e.char

          if (key == Tput::Key::Up || (@vi && ch == 'k'))
            scroll(-1)
            screen.render
            next
          end
          if (key == Tput::Key::Down || (@vi && ch == 'j'))
            scroll(1)
            screen.render
            next
          end

          if @vi
            # XXX remove all those protections for height being Int
            case key
            when Tput::Key::CtrlU
              height.try do |h|
                next unless h.is_a? Int
                offs = -h // 2
                scroll offs == 0 ? -1 : offs
                screen.render
              end
              next
            when Tput::Key::CtrlD
              height.try do |h|
                next unless h.is_a? Int
                offs = h // 2
                scroll offs == 0 ? 1 : offs
                screen.render
              end
              next
            when Tput::Key::CtrlB
              height.try do |h|
                next unless h.is_a? Int
                offs = -h
                scroll offs == 0 ? -1 : offs
                screen.render
              end
              next
            when Tput::Key::CtrlF
              height.try do |h|
                next unless h.is_a? Int
                offs = h
                scroll offs == 0 ? 1 : offs
                screen.render
              end
              next
            end

            case ch
            when 'g'
              scroll_to 0
              screen.render
              next
            when 'G'
              scroll_to get_scroll_height
              screen.render
              next
            end
          end
        end
      end

      if @scrollable
        # XXX also remove handler when scrollable is turned off?
        on(Crysterm::Event::ParsedContent) do
          _recalculate_index
        end

        _recalculate_index
      end

      focus if focused
    end

    # alias_previous :set_scroll

    def self.sattr(style : Style, fg = nil, bg = nil)
      if fg.nil? && bg.nil?
        fg = style.fg
        bg = style.bg
      end

      # TODO support style.* being Procs ?

      # D O:
      # return (this.uid << 24)
      #   | ((this.dockBorders ? 32 : 0) << 18)
      ((style.invisible ? 16 : 0) << 18) |
        ((style.inverse ? 8 : 0) << 18) |
        ((style.blink ? 4 : 0) << 18) |
        ((style.underline ? 2 : 0) << 18) |
        ((style.bold ? 1 : 0) << 18) |
        (Colors.convert(fg) << 9) |
        Colors.convert(bg)
    end

    def sattr(style : Style, fg = nil, bg = nil)
      self.class.sattr style, fg, bg
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

      screen.screenshot xi, xl, yi, yl
    end

    def destroy
      @children.each do |c|
        c.destroy
      end
      deparent
      @destroyed = true
      emit Crysterm::Event::Destroy
    end
  end
end
