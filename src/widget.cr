require "./event"
require "./misc/util/helpers"

require "./mixin/children"
require "./mixin/pos"
require "./mixin/uid"
require "./mixin/data"
require "./mixin/css"

require "./widget_children"
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
require "./widget_label"
require "./widget_cursor"

# Supporting code for widget families under `src/widget/`: `Media` (image) backend
# bases + fitting/decoder, `Graph` rasterizer/scale helpers, shared `Effect`
# animation mixins, `Terminal` backend (pty + emulator), table layout helper.
require "./widget_media_base"
require "./widget_media_cells"
require "./widget_media_graphics"
require "./widget_media_fitting"
require "./widget_media_video_source"
require "./widget_media_ansi_decode"
require "./widget_graph_scale"
require "./widget_graph_painter"
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

    # CSS `state-*` class for this state. Each branch is a string literal
    # (allocation-free), unlike `to_s.downcase`.
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

    # Whether this widget *is* a label box (the child created by `#set_label` to
    # render a widget's title over its border). Distinct from `@_label`, which is
    # non-nil when a widget *has* a label. `coords`' scrollable-ancestor
    # clip uses this to exempt a label from border compensation (a label sits ON
    # its parent's border, so its clip must not be pushed inside by that border).
    protected property? _is_label : Bool = false

    # (Defined here rather than in src/mixin/children.cr because classes with
    # children do not necessarily have a parent, e.g. `Window`.)

    # Reparents this widget under *parent* (Qt's `QWidget::setParent`): detaches
    # it from its current home and appends it to *parent*'s children, so it
    # actually renders there. `nil` detaches without re-attaching.
    #
    # Delegates to `#append`/`#detach_from_tree`, which own the whole relink
    # (unlink, `@parent`/`@window` write, registry re-registration,
    # `Reparent`/`Adopt`/`Attach`/`Detach` events). Those set `@parent` through
    # `#parent_ivar=`, so this never recurses.
    def parent=(parent : Widget?) : Widget?
      return parent if parent == @parent
      if parent
        parent.append self
      else
        detach_from_tree
      end
      parent
    end

    # Writes the `@parent` ivar with no relink — the raw primitive the tree
    # surgery in `widget_children.cr` uses once it has already unlinked/relinked
    # the children lists itself. Everything else must go through `#parent=`.
    #
    # Reparenting invalidates the memoized window (`#window?`) on this node and
    # all descendants, since all reparenting goes through this setter (no direct
    # `@parent` writes). O(subtree), but reparenting is rare vs. per-frame `#window?` reads.
    protected def parent_ivar=(parent : Widget?) : Widget?
      @parent = parent
      invalidate_window_cache
      parent
    end

    # Owning `Window` (the surface) ↔ `QWidget::window()`.
    #
    # Only a top-level widget (no `#parent`) stores this directly; a nested
    # widget derives it from its parent (see `#window?`).
    #
    # Do not read `@window` directly; use `#window` or `#window?`.
    @window : ::Crysterm::Window?

    # Memoized result of the `#window?` parent-chain walk. Cleared across the
    # whole subtree on reparenting (see `#parent=`/`#window=`/`#invalidate_window_cache`).
    # Only ever holds a non-nil window; a detached widget keeps this nil and resolves live.
    @window_cache : ::Crysterm::Window?

    # Returns the `Window` (surface) owning this widget, or `nil` if this widget's
    # subtree is not attached to any window ↔ `QWidget::window()`.
    #
    # Derived by walking up the parent chain; only the top-level widget of the
    # subtree holds the reference. Use this when the window may legitimately be
    # absent; use `#window` when it must be present.
    #
    # Memoized in `@window_cache` since `#window?` is read several times per
    # widget per frame; without it each read would walk parent→…→root every
    # frame. Cleared on reparenting.
    def window? : ::Crysterm::Window?
      if cached = @window_cache
        return cached
      end
      @window_cache = if parent = @parent
                        parent.window?
                      else
                        @window
                      end
    end

    # Clears the memoized `#window?` value on this node and all descendants.
    # Called wherever the tree is relinked.
    protected def invalidate_window_cache : Nil
      self_and_each_descendant &.reset_window_cache
    end

    # Drops this single node's memoized window pointer. Separate from
    # `#invalidate_window_cache` so the subtree walk can call it per node.
    protected def reset_window_cache : Nil
      @window_cache = nil
    end

    # Returns the `Window` (surface) owning this widget, raising if it is not
    # attached to one. See `#window?` for a non-raising variant.
    def window : ::Crysterm::Window
      window?.not_nil! # ameba:disable Lint/NotNil
    end

    # Sets the owning `Window`.
    #
    # Only meaningful on a top-level widget; ignored on a nested widget (whose
    # `#window` derives from `#parent`). Internal to the (re)parenting code in
    # `widget_children.cr`/`window_children.cr`, which writes it as part of a
    # relink it fully owns; user code reparents via `#parent=`/`#append`.
    protected def window=(@window : ::Crysterm::Window?)
      invalidate_window_cache
    end

    # The physical device (`Screen`) this widget is displayed on ↔
    # `QWidget::screen()` — i.e. its window's `Screen`. `nil` when the widget is
    # not attached to any window.
    def screen? : ::Crysterm::Screen?
      window?.try &.screen
    end

    # :ditto: but raises when the widget is not attached to a window.
    def screen : ::Crysterm::Screen
      window.screen
    end

    # Damage tracking (see `OptimizationFlag::DamageTracking`).
    #
    # Coarse per-widget marker set by `#mark_dirty` when this widget's appearance
    # may have changed. The actual repaint decision is driven by the
    # window-level dirty set (`Window#damage_mark_dirty`, recording the
    # top-level ancestor in `@damage_dirty_roots`), not this flag — it's an
    # informational hint, not the gate. Starts `true` so an unpainted widget is
    # treated as needing paint.
    property? render_dirty : Bool = true

    # Bounding rectangle (`{xi, xl, yi, yl}`, half-open) of this widget's whole
    # subtree as of its last paint — union of its own and all descendants'
    # `@lpos`. Maintained only for top-level widgets while damage tracking is on;
    # used to clear a changed subtree's old footprint and test overlap with an
    # unchanged one. `nil` when the subtree rendered to nothing.
    property damage_bounds : Tuple(Int32, Int32, Int32, Int32)? = nil

    # Stamp for `Window`'s damage overlap-grow: O(1) cluster membership test,
    # true iff `@damage_seen` equals the window's current grow stamp. Transient
    # scratch, meaningful only mid-grow. `Int64` so it never wraps.
    property damage_seen : Int64 = 0

    # Index of this widget within the window's base-child list for the current
    # damage frame, used to address the overlap union-find. Transient scratch.
    property damage_idx : Int32 = -1

    # Marks this widget as needing a repaint, registers it (mapped to its
    # top-level ancestor) with the owning window's damage set, and requests the
    # frame that paints it. Safe to call from any state-changing setter. Call
    # after an in-place change the tracked setters don't see (e.g. mutating a
    # `Style` directly). This is Qt's `QWidget::update()` — schedule a repaint,
    # don't force one; `#request_render` is `QWidget::repaint()`.
    #
    # The frame request goes through `Window#request_frame`, so it is skipped
    # while a frame is already being built — layout assigns child geometry
    # through these same setters mid-frame, and that must not re-arm the
    # doorbell from inside the frame it belongs to. The damage registration
    # itself is a no-op when damage tracking is off.
    def mark_dirty : Nil
      @render_dirty = true
      # A dirtying change can alter the resolved style within the same frame
      # (e.g. `hide`/`show` writing `state_style.visible` — the frame-memoized
      # `#style` may hold a detached floor-highlight `dup` that misses it).
      invalidate_frame_style
      # A dirtying change (content, geometry, visibility) can change the
      # shrink-to-content size of this widget AND of any shrink ancestor within
      # the same frame, so drop the whole chain's frame-memoized rectangles.
      invalidate_minimal_rectangle
      p = @parent
      while p
        p.invalidate_minimal_rectangle
        p = p.parent
      end
      window?.try do |w|
        w.damage_mark_dirty self
        w.request_frame
      end
    end

    # Assigns all four geometry ivars (`left`/`top`/`width`/`height`) in one
    # shot, coalescing the side effects the four independent setters would each
    # run on their own. It:
    #
    # * is a full no-op when nothing changed (no `mark_dirty`, no events) — same
    #   change-guard semantics as `left=`/`top=`/`width=`/`height=`;
    # * assigns all four ivars *before* any dispatch, so in-tree listeners see
    #   the final geometry (matches each setter assigning before it emits);
    # * calls `mark_dirty` at most **once** instead of up to four times — the
    #   walk is idempotent within a frame (sets `@render_dirty`, drops the
    #   frame-memoized style/minrect on self + ancestors, re-registers window
    #   damage), so one call leaves the exact same state as four;
    # * emits `Move` only if `left`/`top` changed and `Resize` only if
    #   `width`/`height` changed, so `process_content` (subscribed to `Resize`
    #   by every widget) runs exactly once on a size change — not twice as when
    #   `width=` and `height=` each emit.
    #
    # Used by `Layout#place_child` to reposition/resize a child in a single pass.
    # The individual setters keep their per-axis behavior for direct callers;
    # only this primitive coalesces.
    def set_geometry(left, top, width, height) : Nil
      moved = (@left != left) || (@top != top)
      resized = (@width != width) || (@height != height)
      return unless moved || resized

      @left = left
      @top = top
      @width = width
      @height = height

      mark_dirty
      emit ::Crysterm::Event::Move if moved
      emit ::Crysterm::Event::Resize if resized
    end

    # Requests a re-render of the owning `Window`, if attached — Qt's
    # `QWidget::repaint()` to `#mark_dirty`'s `QWidget::update()`. Safe form of
    # `window.render` for use after a state change (no-op when detached). Also
    # flags this widget for damage tracking.
    #
    # Unconditional, unlike the request `#mark_dirty` makes: this one still
    # rings the doorbell mid-frame, so it's the right call for a driver that
    # deliberately wants *another* frame after this one (animations,
    # transitions, media decode). For a plain state change prefer `#mark_dirty`
    # — or just the setter, which calls it for you.
    def request_render : Nil
      window?.try do |s|
        s.damage_mark_dirty self
        s.render
      end
    end

    # Structural-change hook (a child was added/removed under this widget).
    # Forces the next frame to a full re-composite, since vacated cells aren't
    # covered by per-subtree damage rects. Mirrors `invalidate_css_tree`.
    protected def _damage_invalidate_structure : Nil
      window?.try &.damage_force_full
    end

    # Whether this widget is an item view (list/tree/table/menu — anything
    # including `Mixin::ItemView`, which sets it). Duck-typed: the renderer keys
    # off this flag plus `#item_selected?` instead of an `is_a?(List)` check.
    #
    # Backed by `@_is_list` rather than `@item_view`: the flag's readers
    # (`widget_size.cr`, `widget_scrolling.cr`) and its lone writer
    # (`Mixin::ItemView`) all touch the ivar directly, so the name is kept while
    # the public spelling moves to `#item_view?`.
    @_is_list = false

    protected def item_view? : Bool
      @_is_list
    end

    # :ditto:
    protected def item_view=(value : Bool) : Bool
      @_is_list = value
    end

    # Whether *item* (a child) renders in the selected style. Base answer is
    # `false`; `Mixin::ItemView` overrides it (publicly — item views expose the
    # query). Lets the render path ask any parent without an `is_a?(List)`
    # special-case.
    protected def item_selected?(item : Widget) : Bool
      false
    end

    def initialize(
      parent = nil,
      *,

      @name = @name,
      window : ::Crysterm::Window? = nil,

      @left = @left,
      @top = @top,
      @right = @right,
      @bottom = @bottom,
      @width = @width,
      @height = @height,
      @shrink_to_fit = @shrink_to_fit,

      visible = nil,
      @fixed = @fixed,
      align : Tput::AlignFlag | Shorthands = @align,
      overflow : Overflow | Shorthands | Nil = @overflow,
      @layout = @layout,
      layout_hint : Crysterm::Layout::Hint | Shorthands | Nil = @layout_hint,

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
      mouse_cursor_shape = nil,
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
      @render_index = -1,
      children = [] of Widget,
    )
      # $ = _ = JSON/YAML::Any

      self.align = align
      self.overflow = overflow
      # Routed through the setter so a bare `Border::Region` (`layout_hint:
      # :top`) is wrapped into a `Border::Hint`; see `#layout_hint=`.
      self.layout_hint = layout_hint
      style.try { |v| @style = v }
      scrollable.try { |v| @scrollable = v }
      input.try { |v| @input = v }
      visible.try { |v| self.style.visible = v }
      # Route through the setter so hover handlers get wired (see
      # `#mouse_cursor_shape=`); a plain `@mouse_cursor_shape = …` would not.
      mouse_cursor_shape.try { |v| self.mouse_cursor_shape = v }

      # An explicit owning `Window` is recorded before parenting (`parent:`
      # still wins, since appending re-derives the window via the tree).
      @window = window if window

      # `parent` may be a `Widget` or a `Window`; appending establishes
      # `#parent` (Widget) or attaches to the `Window`, after which `#window`
      # derives automatically.
      parent.try &.append self

      # Stand-alone widgets (no parent/window) fall back to the global window
      # so they're immediately usable.
      @window ||= determine_window unless window?

      # Register for keyboard input with the window so widgets don't have to do it themselves.
      if @keys || @input
        window?.try &.register_keyable self
      end

      # `draggable: true` installs the default reposition behavior (the splat
      # above only set the `@draggable` flag).
      enable_drag if @draggable

      children.each do |child|
        append child
      end

      set_content content, true
      label.try do |t|
        set_label t, "left"
      end
      hover_text.try do |t|
        self.tool_tip = t
      end

      # on(AddHandlerEvent) { |wrapper| }
      on(Crysterm::Event::Resize) { process_content }
      on(Crysterm::Event::Attach) { process_content }
      # on(Crysterm::Event::Detach) { @lpos = nil } # XXX D O or E O?

      # Legacy `scrollbar: true/false` sugar maps onto `#scrollbar_policy`
      # (`true` ⇒ `AsNeeded`, `false` ⇒ `AlwaysOff`); `nil` leaves the default.
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
      # Stop any animation before this widget goes away. A `#pulse` (or
      # infinite CSS `@keyframes`) is a ticker that never ends on its own; left
      # running it would spin forever on the detached widget. Tween-based ones
      # (fades, tints, transitions) would keep ticking until their duration
      # elapsed. Each stopper is a no-op when nothing is running.
      stop_fade
      stop_tint
      stop_css_animation
      @style_transitions.try &.each_value &.stop

      # Iterate a snapshot: each child's `destroy` calls `remove_from_parent`,
      # mutating `@children` mid-iteration. Without `dup`, index-based `each`
      # would skip every other child, leaking roughly half of them.
      @children.dup.each do |c|
        c.destroy
      end
      # A hover tooltip is a window-level satellite (not a child); drop it here.
      Widget.destroy_satellite @_tooltip
      @_tooltip = nil
      # Detach from wherever this widget lives — a nested widget from its
      # parent, a top-level one from its window — else it would remain in
      # `window.children`: still painted, keyable, possibly holding focus/hover/grab.
      detach_from_tree
      emit Crysterm::Event::Destroy
    end

    # Returns the `Window` a stand-alone (parent-less) widget should attach to:
    # the global window, created on demand if none exists (lets short scripts
    # skip explicit `Window` setup). Widgets with a parent derive `#window`
    # from the parent chain instead (see `#window?`).
    protected def determine_window : ::Crysterm::Window
      Window.global
    end

    # Returns parent `Widget` (if any) or `Window` to which the widget may be attached.
    # If the widget already is `Window`, returns `nil`.
    def parent_or_window
      return self if Window === self
      # `window` raises rather than returning nil when unattached, so
      # `@parent || window` is non-nil without a `not_nil!`.
      @parent || window
    end

    # Captures this widget's on-window region via `Window#capture`, auto-selecting
    # the area it occupies. Forwards all of `Window#capture`'s options (`format`,
    # `path`, `duration`, `fps`, `loops`, …); returns `nil` if not yet rendered.
    #
    # By default captures the whole widget box (including decorations); pass
    # `include_decorations: false` for content area only. `d*` deltas grow/shrink
    # the region per edge in cells.
    #
    # ```
    # widget.capture path: "widget.png"
    # widget.capture format: "gif", duration: 2.seconds
    # ```
    def capture(include_decorations = true, dxi = 0, dxl = 0, dyi = 0, dyl = 0, **opts) : Bytes?
      region = decoration_region(include_decorations, dxi, dxl, dyi, dyl)
      return unless region
      window.capture(*region, **opts)
    end

    # Shared region computation for `#capture`/`#dump`: resolves this widget's
    # on-window box from `@lpos`, applies the `include_decorations` inset and the
    # per-edge `d*` deltas. Returns `nil` if not yet rendered.
    private def decoration_region(include_decorations, dxi, dxl, dyi, dyl)
      lpos = @lpos
      return unless lpos

      xi = lpos.xi + (include_decorations ? 0 : ileft) + dxi
      xl = lpos.xl + (include_decorations ? 0 : -iright) + dxl
      yi = lpos.yi + (include_decorations ? 0 : itop) + dyi
      yl = lpos.yl + (include_decorations ? 0 : -ibottom) + dyl

      {xi, xl, yi, yl}
    end

    # Text counterpart to `Widget#capture`: dumps this widget's on-window region
    # via `Window#dump`. Mirrors `#capture` (same `include_decorations`/`d*`
    # deltas, same option forwarding); returns `nil` if not yet rendered.
    #
    # ```
    # widget.dump                # -> String
    # widget.dump path: "w.dump" # writes the file
    # widget.dump include_decorations: false
    # ```
    def dump(include_decorations = true, dxi = 0, dxl = 0, dyi = 0, dyl = 0, **opts) : String?
      region = decoration_region(include_decorations, dxi, dxl, dyi, dyl)
      return unless region
      window.dump(*region, **opts)
    end
  end
end
