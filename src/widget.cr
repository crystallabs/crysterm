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

    # Owning `Screen`.
    #
    # Only a *top-level* widget (one with no `#parent`) stores this reference
    # directly; a nested widget leaves it `nil` and derives its screen from its
    # parent (see `#screen?`). This way the screen is always consistent with the
    # widget tree and never has to be propagated to, or kept in sync across,
    # descendants.
    #
    # Do not read `@screen` directly; use `#screen` or `#screen?`.
    @screen : ::Crysterm::Screen?

    # Returns the `Screen` owning this widget, or `nil` if this widget's subtree
    # is not attached to any screen.
    #
    # The value is derived by walking up the parent chain; only the top-level
    # widget of the subtree holds the reference. Use this when screen may
    # legitimately be absent; use `#screen` when it must be present.
    def screen? : ::Crysterm::Screen?
      if parent = @parent
        parent.screen?
      else
        @screen
      end
    end

    # Returns the `Screen` owning this widget, raising if it is not attached to
    # one. See `#screen?` for a non-raising variant.
    def screen : ::Crysterm::Screen
      screen?.not_nil!
    end

    # Sets the owning `Screen`.
    #
    # Only meaningful on a top-level widget; on a nested widget `#screen` is
    # derived from `#parent`, so this value is ignored. Normally set only by
    # `Screen`/`Widget` (re)parenting code, not by user code.
    def screen=(@screen : ::Crysterm::Screen?)
    end

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
      children = [] of Widget,
    )
      # $ = _ = JSON/YAML::Any

      style.try { |v| @style = v }
      scrollable.try { |v| @scrollable = v }
      input.try { |v| @input = v }
      visible.try { |v| self.style.visible = v }

      # Set up the parent hierarchy first. The `parent` arg may be a `Widget`
      # or a `Screen`; appending establishes `#parent` (for a Widget) or
      # attaches to the `Screen`, after which `#screen` derives automatically.
      parent.try &.append self

      # If the widget is still stand-alone (created without a parent/screen),
      # fall back to the global screen so it is immediately usable. Once it is
      # later added to a parent or screen, `#screen` derives from there instead.
      @screen ||= determine_screen unless screen?

      # If this widget wants keyboard input, register it with its screen so it
      # receives key events. Widgets no longer have to do this themselves.
      if @keys || @input
        screen?.try &.register_keyable self
      end

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

    # Returns the `Screen` to which a stand-alone (parent-less) widget should
    # attach: the global screen, creating one on demand if none exists yet.
    # (Auto-creation lets short scripts skip explicit `Screen` setup.)
    #
    # Widgets that have a parent do not need this: their `#screen` is derived
    # from the parent chain (see `#screen?`).
    def determine_screen : ::Crysterm::Screen
      Screen.global
    end

    # Returns parent `Widget` (if any) or `Screen` to which the widget may be attached.
    # If the widget already is `Screen`, returns `nil`.
    def parent_or_screen
      return self if Screen === self
      (@parent || screen).not_nil!
    end
  end
end
