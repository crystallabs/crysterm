require "./widget/box"
require "./colors"

module Crysterm
  class Widget
    module Effect
      # Shared self-animation lifecycle for effects that drive their own frame
      # loop. An including widget must be a `Widget` (the loop calls `window`)
      # and define `#step` — advance the simulation and repaint one frame,
      # state and paint only (no `window.render`, no `sleep`). Supplies
      # `#start`/`#stop`/`#toggle` and the fiber loop tying
      # `step` -> `window.render` -> `sleep interval` together.
      #
      # `#step` is public so an effect can also be advanced from an external
      # clock — several effects sharing one frame counter, one `window.render`
      # painting them all.
      #
      # A finite effect (like a non-looping `Spray`) signals the end of its run
      # through the `#done?` / `#on_done` hooks; an endless one leaves them at
      # their defaults and runs until `#stop`.
      module Animated
        # Delay between frames.
        getter interval : Time::Span = 0.07.seconds

        # :ditto:
        # Forwarded to the running `FrameClock`, whose loop reads its own copy
        # live on every tick — so a cadence change (e.g. from a speed slider)
        # applies mid-run instead of silently waiting for the next `#start`.
        def interval=(value : Time::Span) : Time::Span
          @interval = value
          @animation.try &.interval = value
          value
        end

        # The frame clock; non-nil while running.
        @animation : FrameClock?

        # Whether the one-time `Event::Destroy` teardown hook has been installed
        # (lazily, on first `#start`), so it isn't registered on every start.
        @animation_hooks_installed = false

        # Whether the effect is currently animating.
        def running? : Bool
          @animation.try(&.running?) || false
        end

        # Advance the simulation and repaint one frame (state + paint only — no
        # render, no sleep). Defined by the including effect.
        abstract def step

        # Hook re-checked after each painted frame: `true` once a *finite* effect
        # has finished, ending the run. Endless effects never finish and run
        # until `#stop` — the default.
        protected def done? : Bool
          false
        end

        # Hook run exactly once, right after `#done?` first reports `true` and
        # just before the loop exits. Default does nothing.
        protected def on_done
        end

        # Start the animation: an `FrameClock` that steps, renders, and sleeps
        # `interval`, until `#stop` (or, for a finite effect, until `#done?`).
        # A no-op if already running.
        def start
          return if running?
          # Stop the frame clock when the widget is destroyed, or the fiber keeps
          # ticking `step` + `request_render` on the dead widget for the process
          # lifetime. Installed once, on first start.
          unless @animation_hooks_installed
            @animation_hooks_installed = true
            on(::Crysterm::Event::Destroy) { stop }
          end
          @animation = FrameClock.new(@interval) do
            step
            request_render
            if done?
              # End on this frame (so the final state is shown), then notify.
              # `on_done` fires only on natural finish, not an external `#stop`.
              @animation.try &.stop
              on_done
            end
          end
          @animation.try &.start
        end

        # Stop the animation. The fiber exits on its next iteration.
        def stop
          @animation.try &.stop
        end

        def toggle
          running? ? stop : start
        end

        # `{columns, rows}` of this widget's interior hidden by an ancestor clip
        # (a scrolled or `overflow: Hidden` container), for an effect that paints
        # a full-size field of which only a slice may be visible. `coords` moves
        # the rendered rect inward to the clip edge and records the clipped-off
        # top rows in `RenderedGeometry#base`; horizontal clipping has no `base`,
        # so the hidden column count is the distance from *origin_x* — the
        # unclipped interior origin (`aleft` + the left inset) — to the visible
        # interior left edge *xi*. Both are `0` when unclipped, including for a
        # widget merely off the window's top/left edge (negative coords, no
        # clipping ancestor — `base` stays 0 and `xi == origin_x` there).
        protected def clip_offsets(xi : Int32, origin_x : Int32) : {Int32, Int32}
          {Math.max(0, xi - origin_x), lpos.try(&.base) || 0}
        end
      end

      # Shared machinery for "direct" effects — those that paint their interior
      # straight into the window's cell buffer as packed `Int64` attrs (each fg
      # a direct `0xRRGGBB` value), bypassing the `content` -> tag-parse -> SGR
      # -> re-parse pipeline entirely.
      #
      # That pipeline is a content-change path: `_parse_tags` reslices the
      # remaining string on every tag (O(n²)), so driving it every frame for a
      # fully-tagged full-window field is catastrophic — one 80x24 plasma frame
      # copies ~100 MB and parses for ~800 ms, freezing the render fiber (and the
      # input loop, leaking mouse bytes to the terminal). A direct effect computes
      # a glyph and `0xRRGGBB` per cell and writes the packed attr in place, with
      # no per-cell `String`.
      #
      # An including widget is a `Box` and must define (all sizes are the FULL
      # content interior — unclipped by any scrolled/`overflow: Hidden`
      # ancestor, so a partially visible effect keeps simulating its whole
      # field and scrolling never resets it):
      #
      # * `resize(w, h)` — (re)allocate per-area state when the *w*×*h* interior
      #   size changes. Called from `render` before any `cell`.
      # * `advance(w, h)` — step the simulation one frame (state only — no
      #   painting, no strings). Called from `step`, i.e. once per frame.
      # * `cell(x, y, w, h) : {Char, Int32}` — the glyph and fg color (a packed
      #   `0xRRGGBB`, or `-1` to keep the widget's default fg) for interior cell
      #   `{x, y}`. Called once per cell per frame; must not allocate.
      #
      # Drives its own animation (`#start`/`#stop`) like the other effects;
      # `#step` (state only) is public so several effects can share one
      # external clock, with a single `window.render` painting them all.
      module Direct
        include Animated

        # Interior size seen at the last paint, so `#step` can advance the
        # simulation at the right size without needing the window.
        @cols = 0
        @rows = 0

        # Advance the simulation one frame (state only). Public so the effect can
        # be driven from an external clock instead of its own fiber.
        def step
          advance @cols, @rows
          mark_dirty # repaint under damage tracking
        end

        # Position via the normal `Box` render (borders, background, docking and
        # `@lpos`), then overwrite the interior cells directly from `#cell`.
        def render(with_children = true)
          with_content_coords(with_children) do |xi, xl, yi, yl|
            paint xi, xl, yi, yl
          end
        end

        # Paint the current simulation state into the window's cell buffer, given
        # the interior content rectangle from `with_content_coords`.
        private def paint(xi : Int32, xl : Int32, yi : Int32, yl : Int32)
          w = xl - xi
          h = yl - yi
          return if w <= 0 || h <= 0
          lines = window.lines
          # Simulate at the UNCLIPPED content size. An ancestor clip (a scrolled
          # or `overflow: Hidden` container) shrinks the *visible* rect per
          # scroll step; sizing the simulation from it would `resize` — i.e.
          # wipe — the whole state on every step, while also squashing the field
          # into the visible slice. Instead the field stays full-size and the
          # visible cells map into it through `clip_offsets` (hidden top rows
          # from `coords.base`, hidden left columns from the unclipped content
          # origin), matching the `Widget::Terminal#draw` clipping convention.
          full_w = Math.max(0, awidth - ihorizontal)
          full_h = Math.max(0, aheight - ivertical)
          return if full_w <= 0 || full_h <= 0
          if full_w != @cols || full_h != @rows
            @cols, @rows = full_w, full_h
            resize full_w, full_h
          end
          col_off, row_off = clip_offsets(xi, aleft + ileft)

          # Default attr carries the widget's bg/flags; only the fg varies per
          # cell, so `Attr.with_fg` reuses `da`'s flags/bg/Opaque alpha.
          da = style_to_attr style
          deff = Attr.fg da

          # Absolute coords (`yi`/`xi`) can be negative when the widget is
          # partly off the top/left edge. `Row`/`lines` are `Indexable`, so a
          # negative index wraps to the end and would corrupt the bottom/right
          # of the terminal — start each loop past the offscreen band instead.
          (Math.max(0, -yi)...h).each do |ry|
            fy = ry + row_off
            break if fy >= full_h
            line = lines[yi + ry]?
            next unless line
            (Math.max(0, -xi)...w).each do |rx|
              fx = rx + col_off
              break if fx >= full_w
              c = line[xi + rx]?
              next unless c
              ch, color = cell fx, fy, full_w, full_h
              fgf = color < 0 ? deff : Attr.pack_color(color)
              a = Attr.with_fg(da, fgf)
              if c.attr != a || c.char != ch
                c.attr = a
                c.char = ch
                line.dirty = true
              end
            end
          end
        end
      end
    end
  end
end
