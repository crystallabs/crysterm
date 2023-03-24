require "./event"
require "./helpers"

require "./mixin/children"
require "./mixin/pos"
require "./mixin/uid"
require "./mixin/data"

require "./widget_children"
require "./widget_content"
require "./widget_rendering"
require "./widget_position"
require "./widget_scrolling"
require "./widget_interaction"
require "./widget_label"

module Crysterm
  class Widget
    include EventHandler
    include Mixin::Name
    include Mixin::Uid
    include Mixin::Pos
    include Mixin::Style
    include Mixin::Data

    @auto_padding = true

    # Widget's parent `Widget`, if any.
    property parent : Widget?
    # (This must be defined here rather than in src/mixin/children.cr because classes
    # which have children do not necessarily also have a parent, e.g. `Screen`.)

    # Screen owning this element, forced to non-nil at time of access.
    # Each element must belong to a Screen if it is to be rendered/displayed anywhere.
    # If you just want to test for screen being set, use `#screen?`.
    property! screen : ::Crysterm::Screen?

    # :ditto:
    getter? screen

    # XXX FIX by removing at some point
    # Used only for lists. The reason why it hasn't been replaced with is_a?(List)
    # already is because maybe someone would want this to be true even if not
    # inheriting from List.
    property _is_list = false

    def initialize(
      parent = nil,
      *,

      @name = @name,
      @screen = @screen,

      @left = @left,
      @top = @top,
      @right = @right,
      @bottom = @bottom,
      @width = @width,
      @height = @height,
      @resizable = @resizable,

      visible = nil,
      @fixed = @fixed,
      @align = @align,
      @overflow = @overflow,

      @scrollbar = @scrollbar,
      # TODO Make it configurable which side it appears on etc.
      @track = @track,
      # XXX Should this whole section of 5 properties be in Style?

      content = "",
      @parse_tags = @parse_tags,
      @wrap_content = @wrap_content,

      label = nil,
      hover_text = nil,
      # TODO Unify naming label[_text]/hover[_text]

      scrollable = nil,
      # hover_bg=nil,
      @draggable = @draggable,
      focused = false,
      @focus_on_click = @focus_on_click,
      @keys = @keys,
      input = nil,
      style = nil,
      @styles = @styles,

      # Final, misc settings
      @index = -1,
      children = [] of Widget,
      tabc = nil
    )
      # $ = _ = JSON/YAML::Any

      style.try { |v| @style = v }
      scrollable.try { |v| @scrollable = v }
      input.try { |v| @input = v }
      visible.try { |v| self.style.visible = v }
      @tabc = tabc || (" " * self.style.tab_size)

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

      if @scrollable
        # XXX also remove handler when scrollable is turned off?
        on(Crysterm::Event::ParsedContent) do
          _recalculate_index
        end

        _recalculate_index
      end

      focus if focused
    end

    # Takes screenshot of a widget.
    #
    # Does not include decorations, but content only.
    #
    # It is possible to influence the coordinates that will be
    # screenshot with the 4 arguments to the function, but they
    # are not intuitive.
    def screenshot(xi = nil, xl = nil, yi = nil, yl = nil)
      lpos = @lpos
      return unless lpos

      xi = lpos.xi + ileft + (xi || 0)
      if xl
        xl = lpos.xi + ileft + (xl || 0)
      else
        xl = lpos.xl - iright
      end

      yi = lpos.yi + itop + (yi || 0)
      if yl
        yl = lpos.yi + itop + (yl || 0)
      else
        yl = lpos.yl - ibottom
      end

      screen.screenshot xi, xl, yi, yl
    end

    # Takes screenshot of a widget in a more convenient way than `#screenshot`.
    #
    # To take a screenshot of entire widget, just call `#snapshot`.
    # To avoid decorations, use `#snapshot(false)`.
    #
    # To additionally fine-tune the region, pass 'd' values. For example to enlarge the area of
    # screenshot by 1 cell on the left, 2 cells on the right, 3 on top, and 4 on the bottom, call:
    #
    # ```
    # snapshot(true, -1, 2, -3, 4)
    # ```
    #
    # This is hopefully better than the equivalent you would have to use with `#screenshot`:
    #
    # ```
    # screenshot(-ileft - 1, width + iright + 2, -itop - 3, height + ibottom + 4)
    # ```
    def snapshot(include_decorations = true, dxi = 0, dxl = 0, dyi = 0, dyl = 0)
      lpos = @lpos
      return unless lpos

      xi = lpos.xi + (include_decorations ? 0 : ileft) + dxi
      xl = lpos.xl + (include_decorations ? 0 : -iright) + dxl

      yi = lpos.yi + (include_decorations ? 0 : itop) + dyi
      yl = lpos.yl + (include_decorations ? 0 : -ibottom) + dyl

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
      return if self.style.visible?
      self.style.visible = true
      emit Crysterm::Event::Show
    end

    # Hides widget from screen
    def hide
      return if !self.style.visible?
      clear_last_rendered_position
      self.style.visible = false
      emit Crysterm::Event::Hide

      screen.try do |s|
        # s.rewind_focus if focused?
        s.rewind_focus if s.focused == self
      end
    end

    # Toggles widget visibility
    def toggle_visibility
      self.style.visible? ? hide : show
    end

    # Returns whether widget is visible. It also checks the complete chain of widget parents.
    def visible?
      visible = true
      self_and_each_ancestor { |a| visible &= a.style.visible? }
      visible
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
