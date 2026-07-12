module Crysterm
  class Window
    # Things related to rendering (setting up memory state for display)

    # No flags, default fg, default bg. An `Int64` (see `Crysterm::Attr`).
    DEFAULT_ATTR = Attr.pack(0, Attr::COLOR_DEFAULT, Attr::COLOR_DEFAULT)
    DEFAULT_CHAR = ' '

    # Disabled, unused.
    # class BorderStop
    #  property? yes = false
    #  property xi : Int32?
    #  property xl : Int32?
    # end

    # Disabled, unused.
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
    # is the sole owner of the cell buffer (`@lines`) and the only place
    # widgets are painted. Since the default Crystal runtime is
    # single-threaded and fibers are cooperative, the render fiber and the
    # input/handler fibers never run in parallel — they interleave only at
    # yield points — so no locks are needed on widget state.
    #
    # Coordination is a single capacity-1 channel used as a coalescing
    # "doorbell": `schedule_render` rings it (non-blocking; extra rings while
    # one is pending are dropped, batching bursts into one frame), and
    # `render_loop` consumes the ring *before* rendering, so a change made
    # during a render re-rings the doorbell and is picked up next frame (no
    # lost updates). The channel is the only cross-fiber primitive — safe even
    # under multi-threading — so `schedule_render`/`post` may be called from
    # any fiber, but everything they hand off still runs on the one render
    # fiber. Offloaded work should mutate widgets via `post` to land on the
    # render fiber, not concurrently.

    # Coalescing render doorbell (capacity 1: at most one render pending).
    @render_wakeup = Channel(Nil).new 1

    # Set by `#destroy` to make `render_loop` exit on its next wake-up.
    @render_stop = false

    # The fiber currently running `render_loop`, so `#revive` (destroy ->
    # `#connect` rebinding) can wait for the stopped loop to actually exit
    # before respawning — a woken-but-not-yet-exited old fiber would otherwise
    # consume (and coalesce away) the revival repaint's doorbell ring.
    @_render_loop_fiber : Fiber?

    # Generation of the current render/resize loop fibers. `#revive`
    # (destroy -> `#connect` rebinding) bumps it and spawns replacement loops
    # that capture the new value; each loop exits when its captured generation
    # no longer matches, so an old fiber that hasn't yet observed its stop
    # flag terminates instead of racing its replacement for the same doorbell
    # (the stop flags alone can't distinguish old fibers from new — revival
    # must reset them before respawning).
    @loop_generation = 0

    # Closures queued by other fibers to run *on the render fiber*, applied
    # just before the next render. The marshaling boundary (Qt's queued
    # connection / `postEvent`).
    @ui_queue = Channel(Proc(Nil)).new 1024

    # Minimum delay between frames (also the FPS cap, ~60 fps). Kept in seconds.
    property interval : Float64 = Config.render_frame_interval

    # Monotonic time of the last completed render; nil until the first render
    # so the very first request paints immediately.
    @last_render_at : Time::Instant? = nil

    # Rings a coalescing doorbell: a non-blocking send on a capacity-1 channel.
    # If a notification is already pending the send is dropped, so a burst of
    # calls collapses into the single wake-up the loop eventually observes.
    # Shared by `#schedule_render` and `#schedule_resize`.
    private def ring(ch : Channel(Nil)) : Nil
      select
      when ch.send nil
      else
      end
    end

    # Requests a render. Non-blocking and coalescing; safe to call from any
    # fiber. Multiple calls before the frame is produced collapse into one.
    def schedule_render : Nil
      ring @render_wakeup
    end

    # Queues `block` to run on the render fiber just before the next render,
    # then schedules that render. Use to apply results computed off the render
    # fiber (a background fiber, or a thread under `-Dpreview_mt`) to widgets,
    # keeping all widget mutation on the single render fiber — no locks needed.
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
          begin
            job.call
          rescue ex
            # A posted job must never kill the render fiber: a dead render fiber
            # freezes the whole UI and drains no further jobs. Cross-fiber
            # callers that need the failure (e.g. the HTTP bridge's `on_ui`)
            # capture it inside their own job and re-raise on the requesting
            # fiber; here we swallow so the loop survives.
          end
        else
          break
        end
      end
    end

    # Fixed-size ring buffer yielding the running average of the last
    # `capacity` values pushed into it.
    #
    # Wraps a deque rather than subclassing `Deque(Int32)`: subclassing a stdlib
    # generic is deprecated and promotes every `Deque(Int32)` in the program
    # (including unrelated shards) to the virtual type `Deque(Int32)+`, causing
    # confusing compile errors elsewhere (same class of problem as issue #30).
    class Average
      def initialize(@capacity : Int32)
        @deque = Deque(Int32).new @capacity
        # Running sum, kept in sync on every push/shift so `avg` is O(1)
        # instead of re-summing each call. `Int64` because pushed values can be
        # as large as `Int32::MAX` (see `Window#per_second`), and `capacity` of
        # them would overflow an `Int32` sum.
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
    # overlay (or any other observer). Describe the frame just produced. A
    # `Widget::Fps` renders as a child — before these are refreshed — so it
    # always shows the previous frame's numbers, as a frame-rate counter wants.

    # Frames/sec the render (compositing widgets into the cell buffer) phase
    # could sustain: `1 / render_time`. The "R" in the classic `R/D/FPS`.
    getter render_rate : Int32 = 0

    # Frames/sec the draw (diffing the buffer and encoding escapes into the
    # frame buffer) phase could sustain: `1 / draw_time`. The "D". Since the
    # actual terminal write was split into `#flush_frame`, this now measures
    # only the CPU-bound diff/encode — no terminal-backpressure stall.
    getter draw_rate : Int32 = 0

    # Frames/sec the flush (writing the built frame to the terminal) phase could
    # sustain: `1 / flush_time`. On an unbuffered tty this is a blocking
    # `write()`, so it — not `draw_rate` — is where terminal backpressure lands
    # (the write stalls at the terminal's refresh cadence once the per-frame
    # payload exceeds the pty buffer). Separated from `draw_rate` so each figure
    # measures one thing.
    getter flush_rate : Int32 = 0

    # Frames/sec the whole frame could sustain: `1 / (render_time + draw_time)`.
    # The "FPS".
    getter frame_rate : Int32 = 0

    # Bytes/sec the draw phase wrote to the terminal this frame:
    # `last_draw_bytes / frame_time`. An instantaneous, per-frame figure (what
    # continuous rendering would sustain), not a wall-clock average;
    # `Widget::Fps` smooths it via its rolling average.
    getter throughput : Int32 = 0

    # Bytes/sec actually sent to the terminal, measured over wall-clock time:
    # `last_draw_bytes / (this_frame_start - previous_frame_start)`. Unlike
    # `throughput`, divides by the real interval *between* frames (including
    # the idle gap while the render loop parks), so it reflects sustained
    # traffic and integrates over time to `bytes_written`. Zero on the first
    # frame (no previous frame to measure against).
    getter throughput_actual : Int32 = 0

    # Start instant (`t1`) of the previous `_render`, used to compute the
    # wall-clock interval for `throughput_actual`. Nil before the first frame.
    @last_frame_start : Time::Instant? = nil

    # Raw per-frame durations (nanoseconds) of the most recent `_render`,
    # exposed for benchmarking harnesses wanting the precise split without the
    # lossy `Int32` frames/sec rounding of `render_rate`/`draw_rate`.
    getter render_ns_last : Int64 = 0
    getter draw_ns_last : Int64 = 0
    getter flush_ns_last : Int64 = 0

    # `numerator / seconds` as an `Int32`, guarding the sub-microsecond case
    # where `seconds` rounds to zero (avoiding a `1 // 0.0`-style overflow) and
    # clamping large results to `Int32::MAX`.
    private def per_second(numerator, seconds : Float64) : Int32
      return 0 if seconds <= 0
      rate = numerator / seconds
      rate >= Int32::MAX ? Int32::MAX : rate.to_i
    end

    def render_loop(generation : Int32 = 0)
      loop do
        # Park until a render is requested. Consuming the doorbell *here*,
        # before rendering, closes the lost-update window: a `schedule_render`
        # that fires while `_render` runs re-rings it and triggers another frame.
        @render_wakeup.receive
        # Exit when woken by `#destroy`, or when superseded by a newer loop
        # fiber (`#revive` bumped the generation after this fiber spawned).
        break if @render_stop || generation != @loop_generation

        # Apply any posted UI jobs first, on this (the render) fiber.
        drain_ui_queue

        # While disconnected (between a window closing and a reattach), keep
        # the fiber alive but don't paint — `_render` would write to a
        # closed/absent output. `#connect` renders explicitly once bound again.
        next unless @connected

        # Trailing throttle: the first request after an idle period renders
        # immediately; back-to-back requests are spaced out to honor `interval`
        # (the FPS cap) without adding latency to an isolated update.
        @last_render_at.try do |last|
          elapsed = Time.instant - last
          frame = interval.seconds
          sleep(frame - elapsed) if elapsed < frame
        end

        begin
          _render
          @last_render_at = Time.instant
        rescue ex : IO::Error
          # Output vanished mid-paint — almost always because the window was
          # closed (or `#disconnect` ran) in the gap after the `@connected`
          # check above. If no longer connected, expected: swallow it and keep
          # the loop alive for a later `#connect`/reattach. If still connected,
          # it's a genuine output failure, so propagate it.
          raise ex if @connected
        end
      end
    end

    # Rows where line-drawing characters were emitted this frame and need
    # re-evaluation by the docking pass. Populated during rendering by
    # `Widget#register_dock_stops` (borders and `Line` widgets) and consumed
    # by `#_dock`. See `Crysterm::Docking`.
    property _dock_stops = {} of Int32 => Bool

    # Like `#_dock_stops`, but for line-drawing rows emitted by widgets
    # rendering into a *compositing plane* (an overlay, e.g. a `Menu` chain).
    # Docking on the plane's own buffer — not the composited base — joins
    # overlapping overlay borders to each other without joining them to the
    # content the overlay floats over. Collected per plane in
    # `#composite_planes`.
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

    # Dockable borders won't dock if colors/attributes differ. This allows
    # docking regardless, which may produce odd multi-colored borders. Exposed
    # so a widget docking its own line art (e.g. `Widget#dock_rows`) honors the
    # same contrast policy as `#_dock`.
    getter dock_contrast : DockContrast = Config.render_dock_contrast

    property lines = Array(Row).new
    property olines = Array(Row).new

    # Compositing planes, keyed by z-index — one per distinct `z_index` among
    # the layered widgets (see `Plane`). Empty unless something declares a
    # layer, so a plain UI allocates none and the render path is unchanged.
    @planes = {} of Int32 => Plane

    # Widgets deferred to a plane this frame (those with a `style.z_index`, at
    # any nesting depth). Collected during the base render — see
    # `#defer_layer` — and drained by `#composite_planes`. Cleared each frame.
    @layer_widgets = [] of Widget

    # True only while `#composite_planes` is rendering a layer into its plane,
    # so a z-indexed widget *inside* a layer renders inline there instead of
    # being deferred again (nested layers flatten into their enclosing plane
    # for now).
    getter? compositing_layers = false

    # Reused across frames by `#composite_planes` to bucket this frame's layer
    # widgets by `{z-index, layer alpha}`. Clearing the member arrays each
    # frame (rather than `Array#group_by`, which allocates a fresh `Hash` plus
    # one `Array` per z-level every frame) keeps a steady-state layered UI
    # allocation-free. Keyed by alpha as well as z: opacity is applied at fold
    # time per plane, so two independent same-z roots with differing alpha
    # must fold separately — one bucket per z made whichever root was
    # collected first dictate every sibling's translucency.
    @plane_buckets = {} of {Int32, Float64} => Array(Widget)

    # Reused list of this frame's non-empty bucket keys as
    # `{z, first-appearance-seq, alpha}`, sorted in place — folds ascend by z
    # and stay insertion-stable within a z (the seq breaks ties, so same-z
    # alpha groups fold in collection order).
    @sorted_zs = [] of {Int32, Int32, Float64}

    # Defers *el* (a z-indexed widget) to its plane instead of painting inline.
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
    # widget's ordinary `screen.lines[...]` writes land in a plane instead of
    # the base. Restores the base buffer afterward (the plane is then composited).
    private def with_render_target(buf : Array(Row), &)
      saved = @lines
      @lines = buf
      begin
        yield
      ensure
        @lines = saved
      end
    end

    # Renders each of *members* into *pl*'s own buffer with `compositing` set
    # for the duration, so each layer widget paints opaquely into the plane
    # (render-time alpha self-blend suppressed); the layer's translucency is
    # applied once at fold time as the plane's opacity. Shared by the full
    # `#composite_planes` pass and the selective `#damage_plane_composite`
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
    # composites the planes over the base buffer bottom-to-top. A no-op —
    # zero allocation — when nothing declared a z-index.
    private def composite_planes
      return if @layer_widgets.empty?

      @compositing_layers = true
      begin
        # Bucket this frame's layer widgets by {z-index, alpha} into the reused
        # arrays, then composite bottom-to-top (ascending z; insertion-stable
        # within a z via the seq recorded on first appearance). Equivalent to a
        # `group_by` + `keys.sort` but without their per-frame allocations.
        # Empty buckets (a key with widgets on a previous frame but none now)
        # are skipped, matching `group_by`'s never-empty groups.
        @plane_buckets.each_value &.clear
        @sorted_zs.clear
        @layer_widgets.each do |el|
          z = el.style.z_index.not_nil! # ameba:disable Lint/NotNil
          alpha = el.style.alpha? || 1.0
          bucket = (@plane_buckets[{z, alpha}] ||= [] of Widget)
          # First member this frame: record the key (seq = this frame's
          # first-appearance order, so same-z groups stay collection-ordered).
          @sorted_zs << {z, @sorted_zs.size, alpha} if bucket.empty?
          bucket << el
        end
        # Alpha is tweened per frame by transitions/animations, so a fading
        # z-indexed widget mints a near-unique {z, alpha} key every frame;
        # without pruning, stale empty entries (this frame's bucket never
        # touched) would accumulate in @plane_buckets forever. Reused (i.e.
        # non-empty) keys survive this pass untouched.
        @plane_buckets.reject! { |_k, v| v.empty? }

        @sorted_zs.sort!

        @sorted_zs.each do |(z, _seq, alpha)|
          members = @plane_buckets[{z, alpha}]
          pl = plane(z)
          pl.clear
          # The layer's translucency is applied once, here, as the plane's
          # opacity (this group's `alpha`); the widget paints opaquely into
          # the plane (render-time self-blend suppressed while `#compositing`).
          # Same-z groups with different alpha reuse the same plane buffer
          # sequentially (cleared between folds), each with its own opacity.
          pl.opacity = alpha
          @_plane_dock_stops.clear
          render_members_into_plane pl, members
          # Join overlapping overlay borders (e.g. a menu chain) on the plane's
          # own buffer before compositing down. The plane holds only the
          # overlay widgets' cells (everything else transparent), so docking
          # here can't reach into the base content the overlay floats over —
          # fixing stray junctions the base `#_dock` produced where a popup
          # overlapped a widget below it. Gated on `dock_borders`, like the base pass.
          if @dock_borders && !@_plane_dock_stops.empty?
            Docking.dock pl.cells, @_plane_dock_stops, awidth, @dock_contrast, glyph_tier.ascii?
          end
          pl.composite_onto @lines
        end
      ensure
        @compositing_layers = false
      end
    end

    # Docks (joins) all line-drawing characters that cross or meet on the rows
    # collected in `@_dock_stops` this frame. Delegates to `Crysterm::Docking`,
    # shared between border docking and `Line` widget docking.
    def _dock
      Docking.dock @lines, @_dock_stops, awidth, @dock_contrast, glyph_tier.ascii?
    end

    # Delayed render (user render)
    def render
      schedule_render
    end

    # Drives an animation from its own fiber: repeatedly invoke *block*,
    # `render`, then sleep *interval*, until the program exits.
    #
    # Collapses the boilerplate demos repeat everywhere —
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
    # into `screen.every(0.1.seconds) { # ...mutate widgets... }`. The render
    # happens after each block call, so the body only needs to update state.
    #
    # Returns the `FrameClock` driving the loop, so the caller can `#stop` it
    # (phase-locking that keeps the period at `interval` regardless of work
    # cost lives there).
    def every(interval : Time::Span, &block : ->) : FrameClock
      FrameClock.new(interval) do
        block.call
        render
      end.start
    end

    # Real render
    def _render # (draw = true) #@@auto_draw)
      t1 = Time.instant

      # Damage tracking (opt-in) needs to know if styling changed broadly this
      # frame; a stylesheet/cascade change can restyle unrelated widgets, so
      # force a full re-composite. Must run BEFORE `apply_stylesheet_if_dirty`,
      # which clears the dirty flag.
      if @optimization.damage_tracking? && css_dirty?
        damage_force_full
      end

      # Resolve CSS styling (no-op unless a stylesheet is set and dirty) before
      # widgets read their styles for this frame.
      apply_stylesheet_if_dirty

      # Inline auto-grow: resize the region to fit its content before compositing
      # so widgets lay out at the new height (no-op unless `auto_grow`).
      autogrow_reflow

      emit Crysterm::Event::PreRender

      @_dock_stops.clear

      # Reset the effect detector for this frame (see `note_effect`).
      @frame_used_effects = false

      # Compositing: either the selective damage path (when enabled and its
      # preconditions hold) or the full re-composite below, which clears the
      # whole in-memory cell buffer and re-renders every widget from scratch.
      #
      # The full clear is required for correct alpha blending: alpha widgets
      # blend their color into whatever is already in `@lines` (see
      # `Colors.blend` in widget_rendering). Without it, each frame would blend
      # on top of the previous frame's already-blended value, so a
      # semi-transparent field would creep toward full saturation instead of
      # staying constant. It also avoids needing `clear_region` calls wherever
      # an element used to be (e.g. after moving/hiding). It's cheap on the
      # wire: `clear_region`/`fill_region` only mark a line dirty when a cell
      # actually changes, and `draw` still diffs every cell against `@olines`,
      # so unchanged cells produce no output. The damage path replaces this
      # whole-buffer clear with region-aware clears of just the changed
      # subtrees, but only when it can prove output-equivalence (see
      # `window_damage.cr`).
      if @optimization.damage_tracking?
        damage_composite
      else
        damage_full_composite
      end

      t2 = Time.instant

      # Diff + encode this frame into the output buffers (no terminal write —
      # that's `flush_frame` below, timed separately).
      draw flush: false

      t_draw = Time.instant

      # Write the built frame to the terminal. Timed separately from `draw` so
      # the CPU-bound diff/encode and the (blocking, backpressure-prone) tty
      # write each get their own figure — see `draw_rate`/`flush_rate`.
      flush_frame

      t_flush = Time.instant

      # XXX Workaround for cursor pos before the screen has rendered, when lpos
      # is stale. Only some elements implement this; others are a noop.
      #
      # Only the cursor is repositioned here. A focus *event* is NOT emitted:
      # `Event::Focus` denotes a focus *change*, fired once from
      # `window_focus.cr#_focus` when focus actually moves (the rest of the
      # code guards against spurious/duplicate Focus events — see
      # `Widget#focus` and `_focus`'s `old == cur` handling). Re-emitting it
      # every frame would fire all its focus side effects per render — e.g.
      # `Widget::Terminal` reporting focus-in (`\e[I`) to its child PTY, a
      # `text_editing` widget with `input_on_focus` re-entering `read_input`,
      # `action_bar`/`menu_bar`/`completer`/remote DOM observers re-running
      # their focus handlers — none of which the cursor workaround needs.
      focused.try do |focused_widget|
        focused_widget._update_cursor(true)
      end

      @renders += 1

      emit Crysterm::Event::Rendered

      t3 = Time.instant

      # Record this frame's performance figures so an optional `Widget::Fps`
      # overlay can display them (see getters above). Always computed — cheap
      # arithmetic — but nothing is drawn unless a widget reads them.
      @render_ns_last = (t2 - t1).total_nanoseconds.to_i64
      @draw_ns_last = (t_draw - t2).total_nanoseconds.to_i64
      @flush_ns_last = (t_flush - t_draw).total_nanoseconds.to_i64
      @render_rate = per_second 1, (t2 - t1).total_seconds
      @draw_rate = per_second 1, (t_draw - t2).total_seconds
      @flush_rate = per_second 1, (t_flush - t_draw).total_seconds
      @frame_rate = per_second 1, (t3 - t1).total_seconds
      @throughput = per_second @last_draw_bytes, (t3 - t1).total_seconds

      # Sustained, wall-clock throughput: this frame's bytes over the real
      # interval since the previous frame started (idle gap included). Skipped
      # on the first frame, with no previous start to measure from.
      if prev = @last_frame_start
        @throughput_actual = per_second @last_draw_bytes, (t1 - prev).total_seconds
      end
      @last_frame_start = t1
    end

    # TODO Instead of self, return an object reporting the position like LPos.
    # Not necessary until screen is always from (0,0) to (height,width).
    def last_rendered_position
      self
    end
  end
end
