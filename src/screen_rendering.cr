module Crysterm
  class Window
    # Things related to rendering (setting up memory state for display)

    # No flags, default fg, default bg. An `Int64` (see `Crysterm::Attr`).
    DEFAULT_ATTR = Attr.pack(0, Attr::COLOR_DEFAULT, Attr::COLOR_DEFAULT)
    DEFAULT_CHAR = ' '

    # Note: Disabled since nothing uses it.
    # class BorderStop
    #  property? yes = false
    #  property xi : Int32?
    #  property xl : Int32?
    # end

    # Note: Disabled since nothing uses it.
    # class BorderStops < Hash(Int32, BorderStop)
    #  def []=(idx : Int32, arg)
    #    self[idx]? || (self[idx] = BorderStop.new)
    #    case arg
    #    when Bool
    #      self[idx].yes = arg
    #    else
    #      self[idx].xi = arg.xi
    #      self[idx].xl = arg.xl
    #    end
    #  end
    # end

    # ---- Single-threaded rendering model -----------------------------------
    #
    # Crysterm renders on ONE fiber, Qt-style. The render fiber (`render_loop`)
    # is the sole owner of the cell buffer (`@lines`) and the only place widgets
    # are painted to it. Because the default Crystal runtime is single-threaded
    # and fibers are cooperative, the render fiber and the input/handler fibers
    # never run in parallel — they interleave only at yield points — so NO locks
    # are needed on widget state.
    #
    # Coordination is a single capacity-1 channel used as a coalescing
    # "doorbell": `schedule_render` rings it (non-blocking; extra rings while one
    # is already pending are dropped, which batches bursts into one frame), and
    # `render_loop` consumes the ring *before* rendering, so a change made during
    # a render re-rings the doorbell and is picked up by the next frame (no lost
    # updates). The channel is the only cross-fiber primitive and channels are
    # safe even under multi-threading, so `schedule_render`/`post` may be called
    # from any fiber — but everything they hand off still runs on the one render
    # fiber. If you ever offload heavy work to another fiber/thread, mutate
    # widgets via `post` so it happens on the render fiber, not concurrently.

    # Coalescing render doorbell (capacity 1: at most one render pending).
    @render_wakeup = Channel(Nil).new 1

    # Set by `#destroy` to make `render_loop` exit on its next wake-up.
    @render_stop = false

    # Closures queued by other fibers to run *on the render fiber*, applied just
    # before the next render. This is the marshaling boundary (Qt's queued
    # connection / `postEvent`).
    @ui_queue = Channel(Proc(Nil)).new 1024

    # Minimum delay between frames (also the FPS cap, ~60 fps). Kept in seconds.
    property interval : Float64 = Config.render_frame_interval

    # Monotonic time of the last completed render; nil until the first render so
    # that the very first request paints immediately.
    @last_render_at : Time::Instant? = nil

    # Requests a render. Non-blocking and coalescing; safe to call from any
    # fiber. Multiple calls before the frame is produced collapse into one.
    def schedule_render : Nil
      select
      when @render_wakeup.send nil
        # Doorbell rung; a render is now pending.
      else
        # A render is already pending — coalesce (nothing to do).
      end
    end

    # Queues `block` to run on the render fiber just before the next render, then
    # schedules that render. Use this to apply results computed off the render
    # fiber (a background fiber, or a thread under `-Dpreview_mt`) to widgets,
    # keeping ALL widget mutation on the single render fiber — no locks needed.
    def post(&block : Proc(Nil)) : Nil
      @ui_queue.send block
      schedule_render
    end

    # Runs every currently-queued `post` closure on the render fiber. Drains
    # without blocking (stops as soon as the queue is empty).
    private def drain_ui_queue
      loop do
        select
        when job = @ui_queue.receive
          job.call
        else
          break
        end
      end
    end

    # Fixed-size ring buffer that yields the running average of the last
    # `capacity` values pushed into it.
    #
    # This used to subclass `Deque(Int32)`. Subclassing a stdlib generic is
    # deprecated, and—more importantly—it promotes every `Deque(Int32)` in the
    # whole program (including in unrelated shards) to the virtual type
    # `Deque(Int32)+`, which produces confusing compile errors far away from
    # here (same class of problem as issue #30). It now *wraps* a deque instead.
    class Average
      def initialize(@capacity : Int32)
        @deque = Deque(Int32).new @capacity
        # Running sum of the deque's contents, kept in sync on every push/shift
        # so `avg` is O(1) instead of re-summing the whole deque each call. Kept
        # as `Int64` because the pushed values can be as large as `Int32::MAX`
        # (see `Window#per_second`), and `capacity` of them would overflow an
        # `Int32` sum.
        @sum = 0_i64
      end

      def avg(value : Int32) : Int64
        if @deque.size == @capacity
          @sum -= @deque.shift
        end
        @deque.push value
        @sum += value
        @sum // @deque.size
      end
    end

    # ---- Per-frame performance measurements --------------------------------
    #
    # Updated at the end of every `_render`; read by an optional `Widget::Fps`
    # overlay (or any other observer). They describe the frame that was *just*
    # produced. A `Widget::Fps` renders as a child — before these are refreshed —
    # so it always shows the previous frame's numbers, which is exactly what a
    # frame-rate counter wants.

    # Frames/sec the render (compositing widgets into the cell buffer) phase
    # could sustain: `1 / render_time`. The "R" in the classic `R/D/FPS`.
    getter render_rate : Int32 = 0

    # Frames/sec the draw (diffing the buffer and writing escapes) phase could
    # sustain: `1 / draw_time`. The "D".
    getter draw_rate : Int32 = 0

    # Frames/sec the whole frame could sustain: `1 / (render_time + draw_time)`.
    # The "FPS".
    getter frame_rate : Int32 = 0

    # Bytes/sec the draw phase wrote to the terminal this frame:
    # `last_draw_bytes / frame_time`. Like the rates above this is an
    # instantaneous, per-frame figure (what continuous rendering would sustain),
    # not a wall-clock average; `Widget::Fps` smooths it via its rolling average.
    getter throughput : Int32 = 0

    # Bytes/sec actually sent to the terminal, measured over wall-clock time:
    # `last_draw_bytes / (this_frame_start - previous_frame_start)`. Unlike
    # `throughput` this divides by the real interval *between* frames (which
    # includes the idle gap while the render loop parks waiting for the next
    # render request), so it reflects sustained traffic and integrates over time
    # to `bytes_written`. Zero on the very first frame, when there is no previous
    # frame to measure against.
    getter throughput_actual : Int32 = 0

    # Start instant (`t1`) of the previous `_render`, used to compute the
    # wall-clock interval for `throughput_actual`. Nil before the first frame.
    @last_frame_start : Time::Instant? = nil

    # Raw per-frame durations (nanoseconds) of the most recent `_render`, exposed
    # for benchmarking harnesses that want the precise split without the lossy
    # `Int32` frames/sec rounding of `render_rate`/`draw_rate`.
    getter render_ns_last : Int64 = 0
    getter draw_ns_last : Int64 = 0

    # `numerator / seconds` as an `Int32`, guarding the sub-microsecond case
    # where `seconds` rounds to zero (a `1 // 0.0`-style overflow) and clamping
    # absurdly large results to `Int32::MAX`.
    private def per_second(numerator, seconds : Float64) : Int32
      return 0 if seconds <= 0
      rate = numerator / seconds
      rate >= Int32::MAX ? Int32::MAX : rate.to_i
    end

    def render_loop
      loop do
        # Park until a render is requested. Consuming the doorbell *here*, before
        # rendering, is what closes the lost-update window: any `schedule_render`
        # that fires while `_render` runs re-rings it and triggers another frame.
        @render_wakeup.receive
        break if @render_stop # woken by `#destroy` to exit cleanly

        # Apply any posted UI jobs first, on this (the render) fiber.
        drain_ui_queue

        # While disconnected (between a window closing and a reattach), keep the
        # fiber alive but do not paint — `_render` would write to a closed/absent
        # output. The reattach (`#connect`) renders explicitly once bound again.
        next unless @connected

        # Trailing throttle: the first request after an idle period renders
        # immediately; back-to-back requests are spaced out to honor `interval`
        # (the FPS cap), without adding latency to an isolated update.
        @last_render_at.try do |last|
          elapsed = Time.instant - last
          frame = interval.seconds
          sleep(frame - elapsed) if elapsed < frame
        end

        begin
          _render
          @last_render_at = Time.instant
        rescue ex : IO::Error
          # The output vanished mid-paint — almost always because the window was
          # closed (or `#disconnect` ran) in the gap after the `@connected` check
          # above. If we are no longer connected this is expected: swallow it and
          # keep the loop alive so a later `#connect`/reattach can paint again. If
          # we are still connected it is a genuine output failure on a live
          # terminal, so let it propagate rather than hide it.
          raise ex if @connected
        end
      end
    end

    # Rows on which line-drawing characters were emitted this frame and which
    # therefore need to be re-evaluated by the docking pass. Populated during
    # rendering by `Widget#register_dock_stops` (for both borders and `Line`
    # widgets) and consumed by `#_dock`. See `Crysterm::Docking`.
    property _dock_stops = {} of Int32 => Bool

    # Like `#_dock_stops`, but for line-drawing rows emitted by widgets rendering
    # into a *compositing plane* (an overlay, e.g. a `Menu` chain). Docking these
    # on the plane's own buffer — not the composited base — joins overlapping
    # overlay borders to each other without ever joining them to the content the
    # overlay floats over. Collected per plane in `#composite_planes`.
    property _plane_dock_stops = {} of Int32 => Bool

    # Rendering optimizations.
    property optimization : OptimizationFlag = OptimizationFlag::None

    # XXX move somewhere else?
    # Default cell attribute
    property default_attr : Int64 = DEFAULT_ATTR

    # XXX move somewhere else?
    # Default cell character
    property default_char : Char = DEFAULT_CHAR

    # Automatically "dock" borders with other elements instead of overlapping,
    # depending on position.
    #     These border-overlapped elements:
    #     ┌─────────┌─────────┐
    #     │ box1    │ box2    │
    #     └─────────└─────────┘
    #     Become:
    #     ┌─────────┬─────────┐
    #     │ box1    │ box2    │
    #     └─────────┴─────────┘
    property? dock_borders : Bool = Config.window_dock_borders

    # Dockable borders will not dock if the colors or attributes are different.
    # This option will allow docking regardless. It may produce odd looking
    # multi-colored borders. Exposed so a widget that docks its own line art
    # (e.g. `Widget#dock_rows`) honors the same contrast policy as `#_dock`.
    getter dock_contrast : DockContrast = Config.render_dock_contrast

    property lines = Array(Row).new
    property olines = Array(Row).new

    # Compositing planes, keyed by z-index — one per distinct `z_index` among the
    # layered widgets (see `Plane`). Empty unless something declares a layer, so
    # a plain UI allocates none and the render path below is unchanged.
    @planes = {} of Int32 => Plane

    # Widgets deferred to a plane this frame (those with a `style.z_index`, at any
    # nesting depth). Collected during the base render — see `#defer_layer` — and
    # drained by `#composite_planes`. Cleared at the start of every frame.
    @layer_widgets = [] of Widget

    # True only while `#composite_planes` is rendering a layer into its plane, so
    # a z-indexed widget *inside* a layer renders inline there instead of being
    # deferred again (nested layers flatten into their enclosing plane for now).
    getter? compositing_layers = false

    # Reused across frames by `#composite_planes` to bucket this frame's layer
    # widgets by z-index. Clearing the existing member arrays each frame (rather
    # than `Array#group_by`, which allocates a fresh `Hash` plus one `Array` per
    # z-level every frame) keeps a steady-state layered UI allocation-free here.
    @plane_buckets = {} of Int32 => Array(Widget)

    # Reused list of the (non-empty) z-indices present this frame, sorted in
    # place — replaces the throwaway arrays from `by_z.keys.sort`.
    @sorted_zs = [] of Int32

    # Defers *el* (a z-indexed widget) to its plane instead of painting it inline.
    # Called from the base render wherever a child would be rendered.
    def defer_layer(el : Widget) : Nil
      @layer_widgets << el
    end

    # Returns the plane for layer *z*, creating it (and sizing it to the screen)
    # on first use; resizes an existing one if the screen has changed size.
    def plane(z : Int32) : Plane
      pl = @planes[z] ||= Plane.new(z, awidth, aheight)
      pl.resize awidth, aheight
      pl
    end

    # Runs *block* with the cell buffer temporarily redirected to *buf*, so a
    # widget's ordinary `screen.lines[...]` writes land in a plane instead of the
    # base. Restores the base buffer afterward (the plane is then composited).
    private def with_render_target(buf : Array(Row), &)
      saved = @lines
      @lines = buf
      begin
        yield
      ensure
        @lines = saved
      end
    end

    # Renders each of *members* into *pl*'s own buffer with its `compositing`
    # flag set for the duration — so each layer widget paints opaquely into the
    # plane (its render-time alpha self-blend suppressed), the layer's
    # translucency being applied once at fold time as the plane's opacity. Shared
    # by the full `#composite_planes` pass and the selective `#damage_plane_composite`
    # (Phase 4); both manage `@compositing_layers` around their own call.
    private def render_members_into_plane(pl : Plane, members : Enumerable(Widget)) : Nil
      with_render_target(pl.cells) do
        members.each do |el|
          el.compositing = true
          el.render
          el.compositing = false
        end
      end
    end

    # Renders every layered widget collected this frame (any widget, at any
    # nesting depth, that declares `style.z_index`) into its plane, then
    # composites the planes over the base buffer bottom-to-top. A no-op — and
    # zero allocation — when nothing declared a z-index.
    private def composite_planes
      return if @layer_widgets.empty?

      @compositing_layers = true
      begin
        # Bucket this frame's layer widgets by z-index into the reused arrays,
        # then composite the planes bottom-to-top (ascending z). Equivalent to
        # the former `group_by` + `keys.sort`, but without their per-frame
        # allocations. Empty buckets (a z that had widgets on a previous frame
        # but none now) are skipped, matching `group_by`'s never-empty groups.
        @plane_buckets.each_value &.clear
        @layer_widgets.each do |el|
          z = el.style.z_index.not_nil! # ameba:disable Lint/NotNil
          (@plane_buckets[z] ||= [] of Widget) << el
        end

        @sorted_zs.clear
        @plane_buckets.each do |z, members|
          @sorted_zs << z unless members.empty?
        end
        @sorted_zs.sort!

        @sorted_zs.each do |z|
          members = @plane_buckets[z]
          pl = plane(z)
          pl.clear
          # The layer's translucency is applied once, here, as the plane's
          # opacity (from the root's `alpha`); the widget paints opaquely into
          # the plane (its render-time self-blend is suppressed while
          # `#compositing`).
          pl.opacity = members.first.style.alpha? || 1.0
          @_plane_dock_stops.clear
          render_members_into_plane pl, members
          # Join overlapping overlay borders (e.g. a menu chain) on the plane's
          # own buffer before it composites down. The plane holds only the overlay
          # widgets' cells (everything else is transparent), so docking here can
          # never reach into the base content the overlay floats over — fixing the
          # stray junctions the base `#_dock` produced where a popup overlapped a
          # widget below it. Gated on `dock_borders`, like the base pass.
          if @dock_borders && !@_plane_dock_stops.empty?
            Docking.dock pl.cells, @_plane_dock_stops, awidth, @dock_contrast
          end
          pl.composite_onto @lines
        end
      ensure
        @compositing_layers = false
      end
    end

    # Docks (joins) all line-drawing characters that cross or meet on the rows
    # collected in `@_dock_stops` this frame. Delegates the actual work to the
    # reusable `Crysterm::Docking` component, which is shared between border
    # docking and `Line` widget docking.
    def _dock
      Docking.dock @lines, @_dock_stops, awidth, @dock_contrast
    end

    # Delayed render (user render)
    def render
      schedule_render
    end

    # Drive an animation from its own fiber: repeatedly invoke *block*, `render`,
    # then sleep *interval*, until the program exits. Returns the spawned
    # `Fiber`.
    #
    # Collapses the animation-loop boilerplate the demos repeat everywhere —
    #
    # ```
    # spawn do
    #   loop do
    #     # ...mutate widgets...
    #     screen.render
    #     sleep 0.1.seconds
    #   end
    # end
    # ```
    #
    # into `screen.every(0.1.seconds) { # ...mutate widgets... }`. Because the
    # render happens after each block call, the body only needs to update state.
    #
    # Returns the `Animation` driving the loop, so the caller can `#stop` it (the
    # phase-locking that keeps the period at `interval` regardless of work cost
    # lives there).
    def every(interval : Time::Span, &block : ->) : Animation
      Animation.new(interval) do
        block.call
        render
      end.start
    end

    # Real render
    def _render # (draw = true) #@@auto_draw)
      t1 = Time.instant

      # Damage tracking (opt-in) needs to know if styling changed broadly this
      # frame; a stylesheet/cascade change can restyle unrelated widgets, so
      # force a full re-composite. Must be captured BEFORE
      # `apply_stylesheet_if_dirty`, which clears the dirty flag.
      if @optimization.damage_tracking? && css_dirty?
        damage_force_full
      end

      # Resolve CSS styling (no-op unless a stylesheet is set and dirty) before
      # widgets read their styles for this frame.
      apply_stylesheet_if_dirty

      emit Crysterm::Event::PreRender

      @_dock_stops.clear

      # Reset the effect detector for this frame (see `note_effect`).
      @frame_used_effects = false

      # Compositing: either the selective damage path (when enabled and all its
      # preconditions hold) or the full re-composite below. The full path clears
      # the whole in-memory cell buffer and re-renders every widget from scratch.
      #
      # The full clear is required for correct alpha/transparency blending: alpha
      # widgets blend their color into whatever is already in `@lines` (see
      # `Colors.blend` calls in widget_rendering). Without it, each frame would
      # blend on top of the previous frame's already-blended value, so a
      # semi-transparent field would creep toward full saturation on every
      # refresh instead of staying constant. It also removes the need to
      # `clear_region` in arbitrary places just to erase a spot where an element
      # used to be (e.g. when it moves or hides). It is cheap on the wire:
      # `clear_region`/`fill_region` only mark a line dirty when a cell actually
      # changes, and `draw` still diffs every cell against `@olines`, so unchanged
      # cells produce no terminal output. The damage path replaces this
      # whole-buffer clear with region-aware clears of just the changed subtrees,
      # but only when it can prove output-equivalence (see `screen_damage.cr`).
      if @optimization.damage_tracking?
        damage_composite
      else
        damage_full_composite
      end

      t2 = Time.instant

      draw

      # XXX Workaround to deal with cursor pos before the screen
      # has rendered and lpos is not reliable (stale).
      # Only some elements have this function; for others it's a noop.
      #
      # Only the cursor is repositioned here. A focus *event* is NOT emitted:
      # `Event::Focus` denotes a focus *change* and is fired once, from
      # `screen_focus.cr#_focus`, when focus actually moves (the rest of the code
      # deliberately guards against spurious/duplicate Focus events — see
      # `Widget#focus` and `_focus`'s `old == cur` handling). Re-emitting it on
      # the focused widget every frame fired all of its focus side effects on each
      # render — e.g. `Widget::Terminal` reporting focus-in (`\e[I`) to its child
      # PTY, a `text_editing` widget with `input_on_focus` re-entering `read_input`,
      # `action_bar`/`menu_bar`/`completer`/remote DOM observers re-running their
      # focus handlers — none of which the cursor workaround needs.
      focused.try do |focused_widget|
        focused_widget._update_cursor(true)
      end

      @renders += 1

      emit Crysterm::Event::Rendered

      t3 = Time.instant

      # Record this frame's performance figures so an optional `Widget::Fps`
      # overlay can display them (see the getters above). Always computed — they
      # are a handful of cheap arithmetic ops — and nothing is drawn unless a
      # widget actually reads them.
      @render_ns_last = (t2 - t1).total_nanoseconds.to_i64
      @draw_ns_last = (t3 - t2).total_nanoseconds.to_i64
      @render_rate = per_second 1, (t2 - t1).total_seconds
      @draw_rate = per_second 1, (t3 - t2).total_seconds
      @frame_rate = per_second 1, (t3 - t1).total_seconds
      @throughput = per_second @last_draw_bytes, (t3 - t1).total_seconds

      # Sustained, wall-clock throughput: this frame's bytes over the real
      # interval since the previous frame started (idle gap included). Skipped on
      # the first frame, where there is no previous start to measure from.
      if prev = @last_frame_start
        @throughput_actual = per_second @last_draw_bytes, (t1 - prev).total_seconds
      end
      @last_frame_start = t1
    end

    # TODO Instead of self, this should just return an object which reports the position
    # like LPos. But until screen is always from (0,0) to (height,width) that's not necessary.
    def last_rendered_position
      self
    end
  end
end
