require "./event"
require "./misc/util/helpers"

require "./mixin/children"
require "./mixin/pos"
require "./mixin/uid"
require "./mixin/data"
require "./mixin/css"

require "./widget_children"
require "./widget_index"
require "./widget_position"
require "./widget_size"
require "./widget_decoration"
require "./widget_visibility"
require "./widget_fade"
require "./widget_transition"
require "./widget_animation"
require "./widget_content"
require "./widget_scrolling"
require "./widget_background"
require "./widget_rendering"
require "./widget_interaction"
require "./widget_capture"
require "./widget_label"
require "./widget_cursor"

# Supporting code for the widget families whose concrete members live under
# `src/widget/`: the abstract `Media` (image) backend bases + fitting/decoder,
# the `Graph` rasterizer/scale helpers, the shared `Effect` animation mixins, the
# `Terminal` backend (pty + emulator), and the table widgets' content-layout helper.
require "./widget_media_base"
require "./widget_media_cells"
require "./widget_media_external"
require "./widget_media_graphics"
require "./widget_media_fit"
require "./widget_media_fitting"
require "./widget_media_video_source"
require "./widget_media_ansi_decode"
require "./widget_graph_scale"
require "./widget_graph_painter"
require "./widget_effect_animated"
require "./widget_effect_direct"
require "./widget_terminal_pty"
require "./widget_terminal_emulator"
require "./widget_table_layout"

module Crysterm
  # States in which a widget can be
  enum WidgetState
    Normal
    Blurred # Blur
    Focused # Focus
    Hovered # Hover
    Selected
    Disabled # Does not react to keyboard input

    # XXX Does state Hidden belong here?
    # Also does 'Unmanaged' belong here, indicating that Crysterm should not be
    # doing state transitions on it?

    # The `state-*` class this state is stamped as in the CSS document (and that
    # ancestor-state selectors are lowered to match). Each branch is a string
    # *literal* — interned, so it allocates nothing — unlike `to_s.downcase`,
    # which the per-widget per-cascade `Widget#to_html` would otherwise call.
    def css_class : String
      case self
      in .normal?   then "state-normal"
      in .blurred?  then "state-blurred"
      in .focused?  then "state-focused"
      in .hovered?  then "state-hovered"
      in .selected? then "state-selected"
      in .disabled? then "state-disabled"
      end
    end
  end

  class Widget
    include EventHandler
    include Macros
    include Mixin::Name
    include Mixin::Uid
    include Mixin::Pos
    include Mixin::Style
    include Mixin::Data
    include Mixin::Css

    # Widget's parent `Widget`, if any.
    getter parent : Widget?

    # (This must be defined here rather than in src/mixin/children.cr because classes
    # which have children do not necessarily also have a parent, e.g. `Screen`.)

    # Reparenting changes the screen this subtree derives (`#screen?`), so the
    # memoized screen pointer on this node *and every descendant* becomes stale.
    # All reparenting goes through this setter (there are no direct `@parent`
    # writes), so invalidating here is sufficient. The walk is O(subtree) but
    # reparenting is rare, unlike the per-frame `#screen?` reads it speeds up.
    def parent=(parent : Widget?)
      @parent = parent
      invalidate_screen_cache
    end

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

    # Memoized result of the `#screen?` parent-chain walk. Cleared across the
    # whole subtree on reparenting (see `#parent=`/`#screen=`/`#invalidate_screen_cache`).
    # Only ever holds a *non-nil* screen — a detached widget leaves this nil and
    # keeps resolving live, so it can never cache a stale screen while detached.
    @screen_cache : ::Crysterm::Screen?

    # Returns the `Screen` owning this widget, or `nil` if this widget's subtree
    # is not attached to any screen.
    #
    # The value is derived by walking up the parent chain; only the top-level
    # widget of the subtree holds the reference. Use this when screen may
    # legitimately be absent; use `#screen` when it must be present.
    #
    # The walk is memoized in `@screen_cache`: `#screen?` is read several times
    # per widget per frame (the coordinate resolvers, `last_rendered_position`,
    # `request_render`, …), and without the cache each read walks parent→…→root
    # (O(depth) × widget count, every frame). The owning screen only changes on
    # reparenting, which clears the cache for the affected subtree.
    def screen? : ::Crysterm::Screen?
      if cached = @screen_cache
        return cached
      end
      @screen_cache = if parent = @parent
                        parent.screen?
                      else
                        @screen
                      end
    end

    # Clears the memoized `#screen?` value on this node and all descendants.
    # Called wherever the tree is relinked, since a node's screen is derived
    # through its ancestors and a move invalidates the whole subtree at once.
    protected def invalidate_screen_cache : Nil
      self_and_each_descendant &.reset_screen_cache
    end

    # Drops this single node's memoized screen pointer. Separate from
    # `#invalidate_screen_cache` so the subtree walk can call it per node.
    protected def reset_screen_cache : Nil
      @screen_cache = nil
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
      # The stored reference is what the subtree derives from, so changing it
      # invalidates the memoized `#screen?` on this node and its descendants.
      invalidate_screen_cache
    end

    # Damage tracking (see `OptimizationFlag::DamageTracking`).
    #
    # Coarse per-widget marker set by `#mark_dirty` whenever this widget's
    # appearance may have changed since it was last painted. Note that the actual
    # repaint decision is driven by the *screen-level* dirty set
    # (`Screen#damage_mark_dirty`, which records the changed widget's top-level
    # ancestor in `@damage_dirty_roots`), not by reading this flag back per
    # widget — so this is an informational hint rather than the gate itself.
    # Starts `true` so a never-yet-painted widget is treated as needing paint.
    property render_dirty : Bool = true

    # Bounding rectangle (`{xi, xl, yi, yl}`, half-open) of this widget's whole
    # subtree as of its last paint — the union of its own and all descendants'
    # `@lpos`. Only maintained for top-level widgets, and only while damage
    # tracking is on; used to clear a changed subtree's old footprint and to test
    # whether a changed subtree overlaps an unchanged one. `nil` when the subtree
    # rendered to nothing.
    property damage_bounds : Tuple(Int32, Int32, Int32, Int32)? = nil

    # Stamp used by `Screen`'s damage overlap-grow for O(1) cluster membership:
    # this widget is in the cluster being assembled iff `@damage_seen` equals the
    # screen's current grow stamp. Transient scratch, meaningful only mid-grow.
    # `Int64` so it never wraps over the lifetime of a process.
    property damage_seen : Int64 = 0

    # Index of this widget within the screen's base-child list for the current
    # damage frame, used to address the overlap union-find. Transient scratch.
    property damage_idx : Int32 = -1

    # Marks this widget as needing a repaint and registers it (mapped to its
    # top-level ancestor) with the owning screen's damage set. Cheap and safe to
    # call from any state-changing setter; a no-op for the buffer when damage
    # tracking is off (the screen simply ignores the registration on a full
    # frame). Call this after an in-place change the tracked setters don't see
    # (e.g. mutating a `Style` directly).
    def mark_dirty : Nil
      @render_dirty = true
      screen?.try &.damage_mark_dirty(self)
    end

    # Requests a re-render of the owning `Screen`, if this widget is attached to
    # one. This is the safe form of `screen.render` for use after a state change
    # (it is a no-op when the widget is detached) and centralizes the
    # render-triggering logic shared across widgets. Also flags this widget for
    # damage tracking, since a render was requested specifically on its behalf.
    def request_render : Nil
      screen?.try do |s|
        s.damage_mark_dirty self
        s.render
      end
    end

    # Structural-change hook (a child was added/removed under this widget). The
    # changed tree can shift unrelated widgets and leave vacated cells the
    # per-subtree damage rects don't cover, so it forces the next frame to be a
    # full re-composite. Mirrors the `invalidate_css_tree` structural hook.
    protected def _damage_invalidate_structure : Nil
      screen?.try &.damage_force_full
    end

    # Marks a widget as an item view (a list/tree/table/menu — anything that
    # includes `Mixin::ItemView`). Duck-typed on purpose: the renderer keys off
    # this flag plus `#item_selected?` rather than an `is_a?(List)` check, so an
    # item view need not derive any one concrete class (Qt makes them siblings).
    property _is_list = false

    # Whether *item* (a child) renders in the selected style. The base answer is
    # `false`; `Mixin::ItemView` overrides it. Defined here so the render path can
    # ask any parent without a concrete-type (`is_a?(List)`) special-case.
    def item_selected?(item : Widget) : Bool
      false
    end

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
      align : Tput::AlignFlag | Shorthands = @align,
      overflow : Overflow | Shorthands | Nil = @overflow,
      @layout = @layout,
      @layout_hint = @layout_hint,

      scrollbar : Bool? = nil,
      @scrollbar_policy = @scrollbar_policy,
      @horizontal_scrollbar_policy = @horizontal_scrollbar_policy,
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

      self.align = align
      self.overflow = overflow
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

      # If constructed `draggable: true`, install the default reposition
      # behavior now (the splat above only set the `@draggable` flag).
      enable_drag if @draggable

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

      # Legacy `scrollbar: true/false` sugar maps onto `#scrollbar_policy`
      # (`true` ⇒ `AsNeeded`, `false` ⇒ `AlwaysOff`). When omitted (`nil`), the
      # class/`scrollbar_policy:` default stands.
      unless scrollbar.nil?
        self.scrollbar = scrollbar
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
      # Stop any animation driving this widget before it goes away. A `#pulse`
      # (and an infinite CSS `@keyframes`) is a *ticker* that never ends on its
      # own, so without this its fiber would spin forever on the now-detached
      # widget — re-running `set_alpha`/`apply_keyframe` and a (no-op)
      # `request_render` for the life of the process. The tween-based ones
      # (fades, tints, transitions) would likewise keep ticking until their
      # duration elapsed. Each stopper is a no-op when nothing is running.
      stop_fade
      stop_tint
      stop_css_animation
      @style_transitions.try &.each_value &.stop

      # Iterate a snapshot: each child's `destroy` calls `remove_from_parent`,
      # which mutates `@children` mid-iteration. Without the `dup`, the
      # index-based `each` would skip every other child, leaking roughly half
      # of them (no `Destroy` event; their PTYs/animations never torn down).
      @children.dup.each do |c|
        c.destroy
      end
      # A hover tooltip is a screen overlay (not a child), so drop it explicitly
      # rather than leaking it past this widget's lifetime.
      if tip = @_tooltip
        tip.screen?.try &.remove tip
        tip.destroy
        @_tooltip = nil
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
      # `screen` already returns a non-nil `Screen` (it raises when unattached),
      # so `@parent || screen` is non-nil without a `not_nil!`.
      @parent || screen
    end
  end
end
