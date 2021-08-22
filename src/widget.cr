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

    property _is_list = false
    # XXX FIX by removing at some point
    # Used only for lists. The reason why it hasn't been replaced with is_a?(List)
    # already is because maybe someone would want this to be true even if not
    # in heriting from List.

    # Amount of padding on the inside of the element
    property padding : Padding

    # Widget's border.
    property border : Border?

    # Draw shadow?
    # If yes, the amount of shadow transparency can be set in `#style.shadow_transparency`.
    property shadow : Shadow?

    # Storage for any user-controlled/miscellaneous data.
    property data : JSON::Any?

    def initialize(
      @parent = nil,
      *,

      @name = nil,
      @uid = next_uid,
      screen = nil,

      @left = nil,
      @top = nil,
      @right = nil,
      @bottom = nil,
      @width = nil,
      @height = nil,
      @resizable = false,

      @hidden = false,
      @fixed = false, # XXX document/check this
      @align = Tput::AlignFlag::Top | Tput::AlignFlag::Left,
      @overflow : Overflow = Overflow::Ignore,

      @style = Style.new, # Previously: Style? = nil

      padding : Padding | Int32 = 0,
      border = nil,
      shadow = nil,
      @scrollbar = false,
      # TODO Make it configurable which side it appears on etc.
      @track = true, # Only has effect within scrollbar
      # XXX Should this whole section of 5 properties be in Style?

      content = "",
      @parse_tags = false,
      @wrap_content = true,

      label = nil,
      hover_text = nil,
      # TODO Unify naming label[_text]/hover[_text]

      @scrollable = false,
      # hover_bg=nil,
      @draggable = false,
      focused = false,
      @focus_on_click = true,
      @keys = false,
      @input = false,

      # Final, misc settings
      @index = -1,
      children = [] of Widget,
      @auto_padding = true,
      @tabc = (" " * style.tab_size)
    )
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

      if screen
        screen.append self
      else
        @screen ||= determine_screen
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

      set_content content, true
      label.try do |t|
        set_label l, "left"
      end
      hover_text.try do |t|
        set_hover t
      end

      # on(AddHandlerEvent) { |wrapper| }
      on(Crysterm::Event::Resize) { process_content }
      on(Crysterm::Event::Attach) { process_content }
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
            self.screen.render
            next
          end
          if (key == Tput::Key::Down || (@vi && ch == 'j'))
            scroll(1)
            self.screen.render
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
                self.screen.render
              end
              next
            when Tput::Key::CtrlD
              height.try do |h|
                next unless h.is_a? Int
                offs = h // 2
                scroll offs == 0 ? 1 : offs
                self.screen.render
              end
              next
            when Tput::Key::CtrlB
              height.try do |h|
                next unless h.is_a? Int
                offs = -h
                scroll offs == 0 ? -1 : offs
                self.screen.render
              end
              next
            when Tput::Key::CtrlF
              height.try do |h|
                next unless h.is_a? Int
                offs = h
                scroll offs == 0 ? 1 : offs
                self.screen.render
              end
              next
            end

            case ch
            when 'g'
              scroll_to 0
              self.screen.render
              next
            when 'G'
              scroll_to get_scroll_height
              self.screen.render
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
      remove_parent
      emit Crysterm::Event::Destroy
    end
  end
end
