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
      # `Effect::Direct`, `Effect::CopperBar`, `Effect::SineScroller`, and
      # `Effect::Spray` all include this. A finite effect (like a non-looping
      # `Spray`) signals the end of its run through the `#done?` / `#on_done`
      # hooks; an endless one leaves them at their defaults and runs until
      # `#stop`.
      module Animated
        # Delay between frames.
        property interval : Time::Span = 0.07.seconds

        # The frame clock; non-nil while running. The loop lives in `FrameClock`.
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
          # Stop the frame clock when the widget is destroyed. Without this the
          # `FrameClock` fiber keeps ticking `step` + `request_render` on the dead
          # widget for the process lifetime (e.g. a `SplashScreen`'s `Effect::Matrix`
          # after `finish`). Installed once, on first start.
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
      end

      # Shared machinery for "direct" effects — those that paint their interior
      # straight into the window's cell buffer as packed `Int64` attrs (each fg
      # a direct `0xRRGGBB` value), bypassing the `content` -> tag-parse -> SGR
      # -> re-parse pipeline entirely.
      #
      # That pipeline is a content-change path: `_parse_tags` reslices the
      # remaining string on every tag (O(n²)), so driving it every frame for a
      # fully-tagged full-window field is catastrophic — a single 80x24 plasma
      # frame copies ~100 MB and parses for ~800 ms, freezing the render fiber
      # (and the input loop, leaking mouse bytes to the terminal). A direct
      # effect instead computes a glyph and `0xRRGGBB` color per cell and writes
      # the packed attr in place, with no per-cell `String`.
      #
      # An including widget is a `Box` and must define:
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

        # Position via the normal `Box` render (borders, background, docking, and
        # `@lpos`), then overwrite the interior cells directly from `#cell`.
        def render(with_children = true)
          super
          paint
        end

        # Paint the current simulation state into the window's cell buffer.
        private def paint
          return unless lpos = @lpos
          lines = window.lines

          # Same border + padding inset the content-draw loop applies, so this
          # paints exactly the interior region.
          xi, xl = lpos.xi, lpos.xl
          yi, yl = lpos.yi, lpos.yl
          if (b = style.border) && b.any?
            xi += b.left
            xl -= b.right
            yi += b.top
            yl -= b.bottom
          end
          p = style.padding
          xi += p.left
          xl -= p.right
          yi += p.top
          yl -= p.bottom

          w = xl - xi
          h = yl - yi
          return if w <= 0 || h <= 0
          if w != @cols || h != @rows
            @cols, @rows = w, h
            resize w, h
          end

          # Default attr carries the widget's bg/flags; only the fg varies per cell.
          da = sattr style
          flags = Attr.flags da
          bgf = Attr.bg da
          deff = Attr.fg da

          (0...h).each do |ry|
            line = lines[yi + ry]?
            next unless line
            (0...w).each do |rx|
              c = line[xi + rx]?
              next unless c
              ch, color = cell rx, ry, w, h
              fgf = color < 0 ? deff : Attr.pack_color(color)
              a = Attr.pack(flags, fgf, bgf)
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
