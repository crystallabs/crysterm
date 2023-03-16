require "./event"
require "./helpers"

require "./mixin/children"
require "./mixin/pos"
require "./mixin/uid"

require "./widget_children"
require "./widget_content"
require "./widget_rendering"
require "./widget_position"
require "./widget_scrolling"
require "./widget_interaction"
require "./widget_label"

module Crysterm
  class Widget < ::Crysterm::Object
    include Mixin::Children
    include Mixin::Pos
    include Mixin::Uid

    @auto_padding = true

    # Widget's parent `Widget`, if any.
    property parent : Widget?
    # (This must be defined here rather than in src/mixin/children.cr because classes
    # which have children do not necessarily also have a parent, e.g. `Screen`.)

    # Screen owning this element, forced to non-nil.
    # Each element must belong to a Screen if it is to be rendered/displayed anywhere.
    # If you just want to test for `Screen`, use `#screen?`.
    property! screen : ::Crysterm::Screen?

    # Screen owning this element, if any.
    # Each element must belong to a Screen if it is to be rendered/displayed anywhere.
    getter? screen : ::Crysterm::Screen?

    # Arbitrary widget name
    property name : String?

    # XXX FIX by removing at some point
    # Used only for lists. The reason why it hasn't been replaced with is_a?(List)
    # already is because maybe someone would want this to be true even if not
    # inheriting from List.
    property _is_list = false

    # XXX move the following three items to Style.

    # Amount of padding on the inside of the element
    property padding : Padding

    # Widget's border.
    property border : Border?

    # Draw shadow?
    # If yes, the amount of shadow transparency can be set in `#style.shadow_transparency`.
    property shadow : Shadow?

    # Widget's complete style definition, a global default.
    # class_property style : Style = Style.new

    # Manages Widget style.
    @[AlwaysInline]
    def style
      s = @style
      focused? ? (s.focus || s) : s
    end

    # :ditto:
    setter style : Style

    # Is element hidden? Hidden elements are not rendered on the screen and their dimensions don't use screen space.
    setter visible = true

    # Storage for any user-controlled/miscellaneous data.
    property data : JSON::Any?

    def initialize(
      parent = nil,
      *,

      @name = nil,
      @uid = next_uid,
      @screen = nil,

      @left = nil,
      @top = nil,
      @right = nil,
      @bottom = nil,
      @width = nil,
      @height = nil,
      @resizable = true,

      @visible = true,
      @fixed = false,
      @align = Tput::AlignFlag::Top | Tput::AlignFlag::Left,
      @overflow : Overflow = Overflow::Ignore,

      @style = Style.new, # Previously: Style? = nil

      padding : Padding | Int32 = 0,
      border = nil,
      shadow = nil,
      @scrollbar = false,
      # TODO Make it configurable which side it appears on etc.
      track = nil, # Only has effect within scrollbar
      # XXX Should this whole section of 5 properties be in Style?

      content = "",
      @parse_tags = false,
      @wrap_content = true,

      label = nil,
      hover_text = nil,
      # TODO Unify naming label[_text]/hover[_text]

      scrollable = nil,
      # hover_bg=nil,
      @draggable = false,
      focused = false,
      @focus_on_click = true,
      @keys = false,
      input = nil,

      # Final, misc settings
      @index = -1,
      children = [] of Widget,
      @tabc = (" " * style.tab_size)
    )
      # $ = _ = JSON/YAML::Any

      scrollable.try { |v| @scrollable = v }
      track.try { |v| @track = v }
      input.try { |v| @input = v }

      @padding = parse_padding padding

      # XXX Move those into mixin/parsers.cr, and put all such methods there
      @border = case border
                when true
                  Border.new type: BorderType::Line
                when nil, false
                  # Nothing
                when BorderType
                  Border.new type: border
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

      # This just defines which Screen it is all linked to.
      # (Until we make `screen` fully optional)
      @screen ||= determine_screen

      # And this takes care of parent hierarchy. Parent arg as passed
      # to this function can be a Widget or Screen.
      parent.try &.append self

      children.each do |child|
        append child
      end

      set_content content, true
      label.try do |t|
        set_label t, "left"
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

    # Takes screenshot of a widget
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
      remove_from_parent
      emit Crysterm::Event::Destroy
    end

    # Shows widget on screen
    def show
      return if visible?
      @visible = false
      emit Crysterm::Event::Show
    end

    # Hides widget from screen
    def hide
      return unless visible?
      clear_last_rendered_position
      @visible = false
      emit Crysterm::Event::Hide

      screen.try do |s|
        # s.rewind_focus if focused?
        s.rewind_focus if s.focused == self
      end
    end

    # Toggles widget visibility
    def toggle_visibility
      @visible ? hide : show
    end

    # Returns whether widget is visible. It also checks the complete chain of widget parents.
    def visible?
      # TODO Revert back to chained lookup eventually
      @visible
      # el = self
      # while el
      #  return false unless el.screen
      #  return false unless el.visible?
      #  el = el.parent
      # end
      # true
    end

    def determine_screen
      scr = if Screen.total <= 1
              # This will use the first screen or create one if none created yet.
              # (Auto-creation helps writing scripts with less code.)
              Screen.global true
            elsif s = @parent
              while s && !(s.is_a? Screen)
                s = s.parent_or_screen
              end
              if s.is_a? Screen
                s
                # else
                #  raise Exception.new("No active screen found in parent chain.")
              end
              # elsif Screen.total > 0
              #  #Screen.instances[-1]
              #  Screen.instances[0]
              #  # XXX For the moment we use the first screen instead of the last one,
              #    as global, so same here - we just return the first one:
            end

      unless scr
        scr = Screen.global
      end

      unless scr
        raise Exception.new("No Screen found anywhere. Create one with Screen.new")
      end

      scr
    end
  end
end
