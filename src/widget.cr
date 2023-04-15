require "./event"
require "./helpers"

require "./mixin/children"
require "./mixin/pos"
require "./mixin/uid"
require "./mixin/data"

require "./widget_children"
require "./widget_index"
require "./widget_position"
require "./widget_size"
require "./widget_decoration"
require "./widget_visibility"
require "./widget_content"
require "./widget_scrolling"
require "./widget_rendering"
require "./widget_interaction"
require "./widget_screenshot"
require "./widget_label"

module Crysterm
  class Widget
    include EventHandler
    include Macros
    include Mixin::Name
    include Mixin::Uid
    include Mixin::Pos
    include Mixin::Style
    include Mixin::Data

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
      @always_scroll = @always_scroll,
      # hover_bg=nil,
      @draggable = @draggable,
      focused = false,
      @focus_on_click = @focus_on_click,
      @keys = @keys,
      @vi = @vi,
      input = nil,
      style = nil,
      @styles = @styles,

      # Final, misc settings
      @index = -1,
      children = [] of Widget
    )
      # $ = _ = JSON/YAML::Any

      style.try { |v| @style = v }
      scrollable.try { |v| @scrollable = v }
      input.try { |v| @input = v }
      visible.try { |v| self.style.visible = v }

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

    def destroy
      @children.each do |c|
        c.destroy
      end
      remove_from_parent
      emit Crysterm::Event::Destroy
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

    # Returns parent `Widget` (if any) or `Screen` to which the widget may be attached.
    # If the widget already is `Screen`, returns `nil`.
    def parent_or_screen
      return self if Screen === self
      (@parent || screen).not_nil!
    end
  end
end
