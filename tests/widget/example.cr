# Shared harness for the per-widget / per-layout examples under `examples/`.
#
# Every generated example is a tiny file that calls `Crysterm::WidgetExample.run`
# with a block that builds *one* widget (or a layout + children) on the given
# screen, and optionally a `script:` that drives it. Runs in one of three modes:
#
#   * **interactive** (default) — a real terminal `Window` plus `exec`. Press `q`
#     or Ctrl-Q to quit.
#
#   * **screenshot** — when `CRYSTERM_SHOT=<path>` is set, the widget is built on
#     a headless screen (all I/O on `IO::Memory`), rendered once, and captured to
#     `<path>` via `Window#capture`.
#
#   * **animation** — when `CRYSTERM_ANIM=<path>` is set (`CRYSTERM_ANIM_SECS`
#     gives duration, default 5), the widget is built headless and `script:` is
#     replayed while `Window#capture(duration:, format: "apng")` records it.
#
# `script:` is expressed with a small `Driver` (below): a thin wrapper over the
# same event `emit`s real input goes through, so demo "rules" read declaratively
# (`d.key :down, times: 4`, `d.type "hi"`, ...).
#
# Styling note: these examples set colors/borders through CSS
# (`screen.stylesheet = "..."`) so the whole demo is themed in one place. An
# inline `style:` also works — like CSS inline style it sits above author rules
# in the cascade (only `!important` and state-specific rules outrank it).
require "../../src/crysterm"

module Crysterm
  module WidgetExample
    # Headless capture size, in cells.
    COLS = (ENV["CRYSTERM_COLS"]?.try(&.to_i?) || 80)
    ROWS = (ENV["CRYSTERM_ROWS"]?.try(&.to_i?) || 24)
    # Animation frame rate. Playback length = frames / FPS; the `Driver` renders
    # FPS times per second of dwell.
    FPS = (ENV["CRYSTERM_ANIM_FPS"]?.try(&.to_i?) || 10)
    # Sim seconds pre-rolled before a still of a self-animating widget, so the
    # capture isn't of a blank first frame.
    PREROLL = 1.5

    # A self-animating widget registers its per-tick advance and tick interval
    # here (see `animate_with`); the harness then drives it itself.
    @@anim_step : (-> Nil)?
    @@anim_interval : Float64 = 0.1
    @@anim_acc : Float64 = 0.0

    # Register a self-animating widget (an `Effect`, `Loading`, ...) by its
    # per-tick advance *step* and tick *interval*. The harness animates it itself
    # rather than letting the widget run its own render fiber: for `--anim` the
    # harness must stay the single frame source (advancing exactly one real frame
    # per recorded frame), or a widget that also rendered would emit extra frames
    # and make the fixed-FPS APNG play back slow. Live and still modes use the
    # same registration, keeping the example file mode-agnostic.
    def self.animate_with(interval : Time::Span, &step : -> Nil)
      @@anim_step = step
      @@anim_interval = interval.total_seconds
    end

    # Advance the registered animation by *dt* real seconds (called once per
    # recorded frame), stepping as many whole ticks as fit so the recording —
    # and thus the playback — runs at the widget's real speed.
    def self.tick_animation(dt : Float64)
      return unless step = @@anim_step
      @@anim_acc += dt
      while @@anim_acc >= @@anim_interval
        step.call
        @@anim_acc -= @@anim_interval
      end
    end

    # Convenience wrapper over `emit` the demo scripts are written against. Each
    # call performs a synthetic input event (the same `emit` real key/mouse input
    # goes through) then renders one or more frames so the action is visible in
    # the recorded animation.
    class Driver
      # Friendly names for the non-printable keys a demo is likely to use.
      KEYS = {
        "down"      => ::Tput::Key::Down,
        "up"        => ::Tput::Key::Up,
        "left"      => ::Tput::Key::Left,
        "right"     => ::Tput::Key::Right,
        "enter"     => ::Tput::Key::Enter,
        "escape"    => ::Tput::Key::Escape,
        "tab"       => ::Tput::Key::Tab,
        "backtab"   => ::Tput::Key::ShiftTab,
        "backspace" => ::Tput::Key::Backspace,
        "delete"    => ::Tput::Key::Delete,
        "home"      => ::Tput::Key::Home,
        "end"       => ::Tput::Key::End,
        "pageup"    => ::Tput::Key::PageUp,
        "pagedown"  => ::Tput::Key::PageDown,
      }

      getter frame_secs : Float64
      # Total demo time (seconds) accumulated so far — used by the measure pass
      # (`record: false`) to size the recording before any frame is captured.
      getter elapsed : Float64 = 0.0

      # In record mode each call emits a real event and renders frames; in
      # measure mode (no screen) it only tallies `elapsed`, so the animation's
      # length can be computed before recording it.
      #
      # When *dump_io* is set the Driver is in **dump** mode: each action emits
      # its event, the state is settled (CSS transitions run to their end), and
      # one text frame (`Window#dump`) is appended to *dump_io* — the textual
      # analogue of recording one frame per action. `advance` neither sleeps nor
      # renders dwell frames here, since time is irrelevant.
      def initialize(@screen : Window? = nil, fps : Int32 = FPS, @record : Bool = true,
                     @dump_io : IO? = nil)
        @frame_secs = 1.0 / fps
      end

      # Suppresses per-character dump frames while a composite action (`type`)
      # runs, so the action records a single frame at its end rather than one
      # per keystroke.
      @suppress_dump = false

      # Dump mode: settle transitions, render, and append one labelled text frame.
      private def dump_frame(label : String) : Nil
        return if @suppress_dump
        io = @dump_io
        return unless io
        if scr = @screen
          WidgetExample.settle scr
          scr._render
          WidgetExample.frame io, scr, label
        end
      end

      # Press a named special key (`:down`, `:enter`, ...), or `:space` sent as a
      # space character. *times* repeats it; *dwell* is seconds the result stays
      # on screen before the next step.
      def key(name : Symbol | String, *, times : Int32 = 1, dwell : Float64 = 0.3)
        n = name.to_s
        times.times do
          if scr = recording
            if n == "space"
              scr.emit Crysterm::Event::KeyPress, ' '
            elsif k = KEYS[n]?
              scr.emit Crysterm::Event::KeyPress, '\0', k
            else
              raise "Driver#key: unknown key #{name.inspect}"
            end
          end
          advance dwell
        end
        dump_frame "key #{name}#{" x#{times}" if times > 1}"
      end

      # Type a single character key (routes to the focused widget).
      def char(c : Char, *, dwell : Float64 = 0.12)
        recording.try &.emit(Crysterm::Event::KeyPress, c)
        advance dwell
        dump_frame "char #{c.inspect}"
      end

      # Type a string, character by character.
      def type(text : String, *, dwell : Float64 = 0.1)
        @suppress_dump = true
        text.each_char { |c| char c, dwell: dwell }
        @suppress_dump = false
        dump_frame "type #{text.inspect}"
      end

      # Synthesize a left click at cell (*x*, *y*) — a press then a release —
      # routed exactly like a real mouse event.
      def click(x : Int32, y : Int32, *, dwell : Float64 = 0.3)
        if scr = recording
          {::Tput::Mouse::Action::Down, ::Tput::Mouse::Action::Up}.each do |action|
            scr.dispatch_mouse ::Tput::Mouse::Event.new(action, ::Tput::Mouse::Button::Left, x, y)
          end
        end
        advance dwell
        dump_frame "click #{x},#{y}"
      end

      # Escape hatch: run arbitrary code against the screen (e.g. call a widget
      # method directly), then dwell.
      def act(*, dwell : Float64 = 0.3, &block : Window ->)
        recording.try { |scr| block.call scr }
        advance dwell
        dump_frame "act"
      end

      # Hold the current frame for *seconds*. No-op in dump mode (would only
      # duplicate a frame).
      def hold(seconds : Float64)
        advance seconds
      end

      # The screen when recording, else nil (measure pass).
      private def recording : Window?
        @record ? @screen : nil
      end

      # Record mode: render `seconds` worth of frames (so the demo dwells here);
      # measure mode: just add to `elapsed`. Dump mode ignores dwell entirely —
      # frames are taken per-action by `dump_frame`, not per unit of time.
      private def advance(seconds : Float64)
        return if @dump_io
        if scr = recording
          frames = Math.max(1, (seconds / @frame_secs).round.to_i)
          frames.times do
            WidgetExample.tick_animation(@frame_secs) # advance any self-animating widget
            scr._render                               # single frame source
            sleep @frame_secs.seconds
          end
        else
          @elapsed += seconds
        end
      end
    end

    # Entry point used by every example. The block builds the widget(s) on the
    # screen; *script* (when given) drives them in animation mode.
    def self.run(title : String = "Crysterm example", *,
                 script : (Driver ->)? = nil, &build : Window ->)
      # Each capture mode is gated by its own dest env var, independently: with
      # several set (e.g. by `manage-examples --all`) one process produces all
      # of them instead of a build+run per output. With none set, fall through
      # to interactive.
      ran = false
      if dest = ENV["CRYSTERM_SHOT"]?
        screenshot dest, &build
        ran = true
      end
      if dest = ENV["CRYSTERM_DUMP"]?
        dump_run dest, script, &build
        ran = true
      end
      if dest = ENV["CRYSTERM_ANIM"]?
        minimum = ENV["CRYSTERM_ANIM_SECS"]?.try(&.to_f?) || 5.0
        animate dest, minimum, script, &build
        ran = true
      end
      interactive title, &build unless ran
    end

    # Headless text dump, the textual analogue of `animate`. Builds the widget
    # headless, then writes one `Window#dump` frame per scripted action to
    # *dest*: initial state, one after each action (settled), and final state.
    # Rewritten in full each run, so with no behavioral change it reproduces
    # byte-for-byte and `git diff` stays empty; a regression shows as a localized
    # diff in the frame after the action that caused it. No `script:` still gets
    # a single static frame.
    def self.dump_run(dest : String, script : (Driver ->)?, &build : Window ->)
      s = headless
      build.call s
      s._render
      # A self-animating widget has no settled state; pre-roll to a deterministic,
      # representative frame (same as still `screenshot` mode).
      if step = @@anim_step
        (PREROLL / @@anim_interval).to_i.times { step.call }
        s._render
      end

      io = IO::Memory.new
      io << "# crysterm dump (text golden; rewritten each run — git diff is the check)\n"
      frame io, s, "start"
      if script
        script.call Driver.new(s, dump_io: io)
      end
      frame io, s, "end"
      File.write dest, io.to_s
      s.destroy rescue nil
    end

    # Append one labelled text frame (a `Window#dump`) to *io*.
    def self.frame(io : IO, s : Window, label : String) : Nil
      io << "\n=== " << label << " ===\n"
      io << s.dump
    end

    # Runs any in-flight CSS `transition` to its settled end state, so the next
    # dump frame is deterministic rather than a wall-clock-dependent mid-tween.
    # Transitions tick on their own fibers; just sleep until none are running,
    # bounded so a never-ending animation can't hang the dump.
    def self.settle(s : Window, max_steps : Int32 = 400) : Nil
      max_steps.times do
        break unless s.animating?
        sleep 0.005.seconds
      end
    end

    # Real terminal; runs until the user quits. A self-animating widget is driven
    # live on its own interval.
    def self.interactive(title : String, &build : Window ->)
      s = Window.new title: title
      build.call s
      if step = @@anim_step
        s.every(@@anim_interval.seconds) { step.call }
      end
      s.on(Event::KeyPress) do |e|
        if e.char == 'q' || e.key == Tput::Key::CtrlQ
          s.destroy
          exit 0
        end
      end
      s.exec
    end

    # Headless still: build, render once (also establishes a self-animating
    # widget's size so it can be pre-rolled), pre-roll if needed, write the image.
    def self.screenshot(dest : String, &build : Window ->)
      s = headless
      build.call s
      s._render
      if step = @@anim_step
        (PREROLL / @@anim_interval).to_i.times { step.call }
        s._render
      end
      s.capture path: dest
      s.destroy rescue nil
    end

    # Headless animation. Recording length follows the demo: `intro + demo +
    # outro`, never shorter than *minimum* (short demos are padded, long ones
    # run to completion instead of being cut off).
    #
    # The APNG loops forever (`loops: 0`). To make the loop read as endless
    # rather than a hard cut, it opens with a brief intro hold on the initial
    # state and closes with a longer outro hold on the final state (outro also
    # absorbs min-duration padding), so the wrap-around lands on two calm frames.
    def self.animate(dest : String, minimum : Float64, script : (Driver ->)?, &build : Window ->)
      # 1. Measure the demo (no screen, no side effects).
      measure = Driver.new(record: false)
      script.try &.call(measure)
      demo = measure.elapsed

      # 2. Intro/outro holds + total length (>= minimum).
      intro = demo.zero? ? 0.6 : (demo * 0.10).clamp(0.4, 1.0)
      outro = demo.zero? ? 0.8 : (demo * 0.18).clamp(0.7, 1.6)
      total = Math.max(minimum, intro + demo + outro)
      tail = total - intro - demo # outro plus any min-duration padding

      # 3. Record: build fresh, then intro -> demo -> tail. Give the capture a
      #    small wall-clock margin beyond `total` so it can't stop before the last
      #    driven frame is in (extra idle time adds no frames).
      s = headless
      build.call s
      s._render
      d = Driver.new s

      done = Channel(Nil).new
      spawn do
        begin
          s.capture path: dest, format: "apng", duration: (total + 0.5).seconds, fps: FPS, loops: 0
        rescue ex
          STDERR.puts "animation capture failed: #{ex.message}"
        ensure
          done.send nil
        end
      end
      Fiber.yield # let the capture subscribe + emit its first frame

      d.hold intro
      script.try &.call(d)
      d.hold tail if tail > 0
      done.receive
      s.destroy rescue nil
    end

    # A headless screen for capturing. `force_unicode` so widgets emit rich
    # glyphs (braille plots, box-drawing, sextant/octant mosaics) rather than
    # ASCII fallbacks — the captured bitmap font (GNU Unifont) can render them.
    private def self.headless : Window
      Window.new(
        input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
        width: COLS, height: ROWS, force_unicode: true)
    end
  end
end
