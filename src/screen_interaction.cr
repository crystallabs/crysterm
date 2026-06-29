module Crysterm
  class Window
    # File related to interaction on the display

    # Is the focused element grab and receiving all keypresses?
    property? grab_keys : Bool = Config.window_grab_keys

    # Are keypresses being propagated further, or (except ignored ones) not propagated?
    property? propagate_keys : Bool = Config.window_propagate_keys

    # Should the constructor install a default quit handler? When on, pressing
    # `q` (or Ctrl-Q) destroys the screen and exits the program — the behavior
    # every demo used to wire up by hand. Apps that bind those keys themselves
    # can turn it off globally via the `window.default_quit_keys` config option
    # or per-window via `default_quit_keys: false`.
    property? default_quit_keys : Bool = Config.window_default_quit_keys

    # Installs the default quit handler (see `default_quit_keys?`). Called from
    # the constructor; idempotent enough for normal use (one screen, one call).
    protected def install_default_quit_keys
      on(Crysterm::Event::KeyPress) do |e|
        if e.char == 'q' || e.key == Tput::Key::CtrlQ
          destroy
          exit
        end
      end
    end

    # Array of keys to ignore when keys are locked or grabbed. Useful for defining
    # keys that will always execute their action (e.g. exit a program) regardless of
    # whether keys are propagate.
    property always_propagate = Array(Tput::Key).new

    @_keys_fiber : Fiber?

    # XXX Maybe in the future this would not be just `Tput::Key`s (which indicate
    # special keys), but also chars (ordinary letters) as well as sequences (arbitrary
    # sequences of chars and keys).

    # Sets up IO listeners for keyboard (and mouse, but mouse is currently unsupported).
    def listen
      # D O:
      # Potentially reset screen title on exit:
      # if !tput.rxvt?
      #  if !tput.vte?
      #    tput.set_title_mode_feature 3
      #  end
      #  manipulate_window(21) { |err, data|
      #    return if err
      #    @_original_title = data.text
      #  }
      # end

      # Listen for keys/mouse on input
      # if (@tput.input._our_input == 0)
      #  @tput.input._out_input = 1
      listen_keys

      # Order matters: `listen_keys` only *spawns* the input fiber, and that fiber
      # puts the terminal into raw (echo-off) mode as its very first action
      # (`Tput::Input#with_raw_input`, before its first blocking read). Until then
      # the tty is still in cooked mode and echoes everything it receives. If we
      # enabled mouse reporting now, any pointer movement during startup would make
      # the terminal emit report sequences that get echoed straight onto the screen
      # (the garbage seen in the cracktro demo). Yield once so the freshly-spawned
      # fiber runs up to that first read — establishing raw mode — and only then
      # turn mouse reporting on. (Tput remains the sole owner of raw mode, so
      # teardown/restore is unaffected.)
      Fiber.yield

      listen_mouse

      # Enable, by default, the input enhancements that are safe and universally
      # expected — done here (after raw mode is established, like mouse, so the
      # enable sequences aren't echoed):
      #
      #   * keyboard-protocol *escape-code disambiguation* — a pure-correctness
      #     win (Esc is instant, Tab/Ctrl+I et al. become distinguishable via
      #     `key_event`) that projects back onto the legacy `key`/`char`, so it
      #     does not change the event stream; no-op on unsupported terminals.
      #   * bracketed paste — so a paste arrives as `Event::Paste` rather than
      #     being interpreted as keystrokes; harmless on unsupported terminals.
      #
      # Modifier/release reporting (`enable_keyboard_protocol(events: true)`)
      # stays opt-in, since it changes the event stream.
      #
      # Only negotiate these with a real terminal: writing the enable sequences
      # to a pipe/file (a non-tty output) would just corrupt the output stream.
      out = tput.output
      if out.responds_to?(:tty?) && out.tty?
        enable_keyboard_protocol
        enable_bracketed_paste

        # In-band resize (DEC 2048): enable it when the terminal advertises
        # support (probed via DECRQM). When active, the SIGWINCH-driven path
        # stands down (see the resize subscription) and resize reports arrive
        # through the input stream instead — but both funnel into the same
        # `Event::Resize`, so apps see resizing identically regardless of
        # mechanism.
        enable_in_band_resize if tput.features.in_band_resize?
      end
      # else
      #  @tput.input._our_input += 1
      # end

      # TODO Do this if it's possible to get resize events on individual IOs.
      # Listen for resize on output
      # if (@output._our_output==0)
      #  @output._our_output = 1
      #  listen_output
      # else
      #  @output._our_output += 1
      # end
    end

    # Starts emitting `Event::KeyPress` events on key presses.
    #
    # Keys are listened for in a separate `Fiber`. There should be at most 1.
    def listen_keys
      return if @_keys_fiber
      @_keys_fiber = spawn {
        # `tput.listen` blocks reading `@input` and returns when it hits EOF — so
        # `#disconnect` stops this fiber simply by closing the input. The rescue
        # swallows the IO error (and the raw-mode-restore error on the now-dead
        # fd) that closing mid-read produces, letting the fiber end quietly.
        begin
          tput.listen { |e| dispatch_input e }
        rescue
        end
      }
    end

    # Whether an enhanced keyboard protocol was enabled for this screen (so
    # `#restore_terminal` knows to turn it back off).
    getter? _listened_keyboard = false

    # Turns on the best enhanced keyboard protocol (kitty / modifyOtherKeys) the
    # terminal supports — honoring the `keyboard.exclude` / `keyboard.protocol`
    # config — so `Event::KeyPress#key_event` is populated. With *events* `true`,
    # also requests key releases and lone-modifier presses (e.g. a "tap Alt"
    # gesture); with `false`, only escape-code disambiguation, which never
    # changes how ordinary typing is delivered. A no-op fallback to the legacy
    # baseline on terminals that support neither protocol.
    def enable_keyboard_protocol(events : Bool = false) : ::Tput::KeyboardProtocol
      @_listened_keyboard = true
      tput.enable_keyboard_protocol events
    end

    # Turns the enhanced keyboard protocol back off, restoring the terminal's
    # default keyboard reporting.
    def disable_keyboard_protocol : Nil
      tput.disable_keyboard_protocol
      @_listened_keyboard = false
    end

    # Whether bracketed paste was enabled for this screen.
    getter? _listened_paste = false

    # Enables bracketed paste (DEC 2004): pasted text arrives as
    # `Event::Paste` instead of as individual key presses.
    def enable_bracketed_paste : Nil
      @_listened_paste = true
      tput.enable_bracketed_paste
    end

    # Disables bracketed paste.
    def disable_bracketed_paste : Nil
      tput.disable_bracketed_paste
      @_listened_paste = false
    end

    # Whether in-band resize notifications were enabled for this screen.
    getter? _listened_in_band_resize = false

    # Enables in-band resize notifications (DEC 2048): the terminal reports size
    # changes through the input stream, feeding the same debounced redraw path
    # as `SIGWINCH` (useful where SIGWINCH is unavailable, e.g. over some PTYs).
    def enable_in_band_resize : Nil
      @_listened_in_band_resize = true
      tput.enable_in_band_resize
    end

    # Disables in-band resize notifications.
    def disable_in_band_resize : Nil
      tput.disable_in_band_resize
      @_listened_in_band_resize = false
    end

    # Whether color-scheme notifications were enabled for this screen.
    getter? _listened_color_scheme = false

    # Enables light/dark color-scheme change notifications (DEC 2031): theme
    # changes arrive as `Event::ColorScheme`. No-op on unsupported terminals.
    def enable_color_scheme_notifications : Nil
      @_listened_color_scheme = true
      tput.enable_color_scheme_notifications
    end

    # Disables color-scheme change notifications.
    def disable_color_scheme_notifications : Nil
      tput.disable_color_scheme_notifications
      @_listened_color_scheme = false
    end

    # OSC 52: copies *text* to the terminal clipboard *selection* (`"c"`
    # clipboard, `"p"` primary). Works over SSH/tmux; ignored where unsupported.
    def copy(text : String, selection : String = "c") : Nil
      tput.set_clipboard text, selection
    end

    # OSC 52: asks the terminal for the clipboard *selection*. The contents
    # arrive asynchronously as an `Event::Paste` (so it works during the input
    # loop). Many terminals disable clipboard *reads* for security, in which case
    # no event arrives.
    def request_clipboard(selection : String = "c") : Nil
      tput.request_clipboard selection
    end

    # OSC 7: reports *path* to the terminal as the current working directory, so
    # terminals that track it ("open new tab/split here", titles) follow along.
    # *host* is the URI host (empty = local). Routed through tput (tmux-safe);
    # ignored where unsupported.
    def report_cwd(path : String, host : String = "") : Nil
      tput.report_cwd path, host
    end

    # OSC 9;4: drives the terminal's progress indicator (taskbar / tab badge).
    # *state*: 0 = clear, 1 = normal (show *progress*, 0–100), 2 = error,
    # 3 = indeterminate, 4 = warning. Ignored where unsupported.
    def progress(progress : Int32 = 0, state : Int32 = 1) : Nil
      tput.progress progress, state
    end

    # Routes one unit of terminal input (`Tput::InputEvent`) to the right
    # Crysterm event. Mouse reports go through the unified mouse path; a paste
    # becomes an `Event::Paste`; an in-band resize feeds the same debounced path
    # as SIGWINCH; everything else is a key transition — a release (only seen
    # when event reporting is enabled) becomes `Event::KeyRelease` so that
    # `Event::KeyPress` always means a press, with the base `Event::Key` also
    # emitted for listeners that want every transition.
    #
    # :nodoc:
    def dispatch_input(e : Tput::InputEvent) : Nil
      if m = e.mouse
        dispatch_mouse m
      elsif pasted = e.paste
        emit Crysterm::Event::Paste.new pasted
      elsif scheme = e.color_scheme
        emit Crysterm::Event::ColorScheme.new scheme
      elsif r = e.resize
        if r.cols > 0 && r.rows > 0
          # The report carries the new window size in pixels (`0` when unknown), so
          # refresh the cell geometry straight from it — no ioctl/escape round-trip.
          @screen.apply_cell_pixels(r.pixel_width // r.cols, r.pixel_height // r.rows)
          # Hand the authoritative new size in cells to the debounced `#resize`
          # path so it drives the dimensions straight from the report instead of
          # re-probing via the `TIOCGWINSZ` ioctl — that ioctl is exactly what
          # in-band resize (DEC 2048) exists to bypass in environments (some
          # PTYs/multiplexers) where SIGWINCH and the ioctl are unreliable.
          @pending_inband_size = {r.cols, r.rows}
        end
        schedule_resize
      else
        ev = if e.release?
               Crysterm::Event::KeyRelease.new e.char, e.key, e.sequence, e.key_event
             else
               Crysterm::Event::KeyPress.new e.char, e.key, e.sequence, e.key_event
             end
        emit ev
        if handlers(Crysterm::Event::Key).any?
          emit Crysterm::Event::Key, ev
        end
      end
    end

    # Disabled since they exist, but nothing calls them within blessed:
    # def enable_keys(el = nil)
    #  _listen_keys(el)
    # end
    # def enable_input(el = nil)
    #  # _listen_mouse(el)
    #  _listen_keys(el)
    # end

    # Registers `el` as a widget that wants to receive keyboard input. Once
    # registered, the general key listener (`#_listen_keys`) dispatches key
    # presses to it, and it participates in keyboard focus navigation.
    #
    # Widgets do not need to call this themselves: `Widget#initialize`
    # registers them automatically when they ask for keys (`#keys?`/`#input?`).
    def register_keyable(el : Widget)
      return if @keyable.includes? el
      el.keyable = true
      @keyable.push el
    end

    # Sets up the general, screen-level key listener. It receives every
    # `Event::KeyPress` and dispatches it to the focused widget and up its
    # parent tree (until one `#accept`s it). Installed once per screen.
    def _listen_keys
      return if @_listening_keys
      @_listening_keys = true

      # Note: The event emissions used to be reversed:
      # element + screen
      # They are now:
      # screen, element and el's parents until one #accepts it.
      # After the first keypress emitted, the handler
      # checks to make sure grab_keys, propagate_keys, and focused
      # weren't changed, and handles those situations appropriately.

      on(Crysterm::Event::KeyPress) do |e|
        # Keyboard drag-and-drop sensor: Space lifts a focused draggable widget,
        # then Tab/arrows/Space/Escape drive the in-flight drag. Handled before
        # anything else so a drag fully owns the keyboard while it is in flight.
        next if _drag_key_handled e

        # If we're not propagate keys and the key is not on always-propagate
        # list, we're done.
        if !@propagate_keys && !@always_propagate.includes?(e.key)
          next
        end

        # XXX the role of `grab_keys` is a little unclear. It makes sense that
        # enabling it would not emit/announce keys. It could be thought of like:
        # - propagate_keys=false -> stops key handling
        # - grab_keys=true     -> does handle keys, but grabs them, doesn't pass on
        # But this doesn't seem to be the case because, grab_keys can be true,
        # but if it is, there is no code that processes it in any way internally.
        # Maybe the code/hook is missing where all keys are passed onto the widget
        # grab them?

        grab_keys = @grab_keys
        # If key grab is not active, or key is whitelisted, announce it.
        # NOTE See implementation of emit_key --> it emits both the generic key
        # press event as well as a specific key event, if one exists.
        if !grab_keys || @always_propagate.includes?(e.key)
          # XXX
          # emit_key self, e
        end

        # If something changed from the screen key handler, stop.
        if (@grab_keys != grab_keys) || !@propagate_keys || e.accepted?
          next
        end

        # Here we pass the key press onto the focused widget. Then
        # we keep passing it through the parent tree until someone
        # `#accept`s the key. If it reaches the toplevel Widget
        # and it isn't handled, we drop/ignore it.
        #
        # XXX But look at this. Unless the key is processed by screen, it gets
        # passed to widget in focus and from there to its parents. How can a widget
        # on a screen, which is not in focus,
        # When a widget has grabbed keys (e.g. a `PlainTextEdit`/`LineEdit` reading
        # input), the key goes to the focused widget only — it must NOT also
        # propagate up to ancestors, or e.g. typing `j`/`k` into a text field
        # inside a `vi:`-enabled `Form` would both insert the character and
        # trigger the form's navigation. `always_propagate` keys (Tab, etc.) are
        # the deliberate exception: they still bubble so the form can navigate.
        grabbed = @grab_keys && !@always_propagate.includes?(e.key)

        focused.try do |el2|
          while el2 && el2.is_a? Widget
            # A disabled widget does not react to keys, but keys still
            # propagate up to its (possibly enabled) ancestors.
            if el2.keyable? && !el2.disabled?
              emit_key el2, e
            end

            if e.accepted?
              break
            end

            # Stop at the focused widget while keys are grabbed (see above).
            break if grabbed

            el2 = el2.parent
          end
        end

        # Default focus navigation. If no widget consumed the key, `Tab`/
        # `Shift+Tab` move focus to the next/previous focusable widget — the
        # standard behavior users expect from GUI toolkits. Opt out per-screen
        # via `tab_navigation = false`.
        if @tab_navigation && !e.accepted?
          case e.key
          when Tput::Key::Tab
            e.accept
            focus_next
            render
          when Tput::Key::ShiftTab
            e.accept
            focus_previous
            render
          end
        end
      end
    end

    # Emits a Event::KeyPress as usual and also emits an event for
    # the individual key, if any.
    #
    # This allows listeners to not only listen for a generic
    # `Event::KeyPress` and then check for `#key`, but they can
    # directly listen for e.g. `Event::KeyPress::CtrlP`.
    @[AlwaysInline]
    def emit_key(el, e : Event)
      if el.handlers(e.class).any?
        el.emit e
      end
      if e.key
        Crysterm::Event::KeyPress::KEYS[e.key]?.try do |keycls|
          if el.handlers(keycls).any?
            el.emit keycls.new e.char, e.key, e.sequence
          end
        end
      end
    end

    # # Unused
    # def key(key, handler)
    # end

    # def once_key(key, handler)
    # end

    # def remove_key(key, wrapper)
    # end
  end
end
