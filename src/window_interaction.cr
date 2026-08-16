module Crysterm
  class Window
    # File related to interaction on the display

    include Mixin::KeyShortcuts
    include Mixin::SyntheticInput

    # `Mixin::SyntheticInput` backend: a window-level synthetic key takes the
    # exact route a typed key takes past parsing — the window emit whose
    # constructor-installed listener walks the focus chain — plus the
    # `Event::Key` fan-out.
    private def synthesize_key(kp : ::Crysterm::Event::KeyPress) : Nil
      emit_key_transition kp
    end

    # Whether the focused widget has grabbed the keyboard: keys are delivered
    # to it ONLY, with no bubbling up its ancestor chain (so `j` typed into a
    # reading text field can't also drive an enclosing form's `vi_keys`
    # navigation). `#always_propagated_keys` (Tab & co.) are the deliberate
    # exception — they still bubble. Set by reading widgets for the duration of
    # an active read; `Widget#grab_keyboard`/`#release_keyboard` are the Qt
    # spellings.
    property? grab_keys : Bool = Config.window_grab_keys

    # Are keypresses being propagated further, or (except ignored ones) not propagated?
    property? propagate_keys : Bool = Config.window_propagate_keys

    # Whether this window opts into the default quit keys. When on, `q`/Ctrl-Q
    # destroys the window and exits the program, as an app-global hotkey applied
    # before the key reaches any widget. Apps that bind those keys themselves
    # can turn it off.
    property? default_quit_keys : Bool = Config.window_default_quit_keys

    # Keyboard-ownership shorthand bundling the "who owns the keys" toggles.
    # `:app_owns` — the app drives all keys itself: turns off the default
    # `q`/Ctrl-Q quit hotkey (`#default_quit_keys=`) and the framework
    # Tab/Shift-Tab focus cycling (`#tab_navigation=`); name the app's own
    # global hotkeys in `#always_propagated_keys`/`#always_propagated_chars`
    # so they keep bubbling past a grabbing widget. `:framework` (the
    # default state) restores both toggles. Also available as a constructor
    # kwarg: `Window.new key_policy: :app_owns`.
    def key_policy=(policy : Symbol) : Symbol
      case policy
      when :app_owns
        self.default_quit_keys = false
        self.tab_navigation = false
      when :framework
        self.default_quit_keys = true
        self.tab_navigation = true
      else
        raise ArgumentError.new "Unknown key_policy: #{policy.inspect} (expected :framework or :app_owns)"
      end
      policy
    end

    # Array of keys to ignore when keys are locked or grabbed. Useful for defining
    # keys that will always execute their action (e.g. exit a program) regardless of
    # whether keys are propagate.
    property always_propagated_keys = Array(Tput::Key).new

    # Companion to `#always_propagated_keys` for ordinary character keys (e.g.
    # `'q'`): those arrive as a `#char` with a nil `#key`, which a special-key
    # list alone can't name. A key always bubbles when its `#key` is in
    # `#always_propagated_keys` OR its `#char` is here.
    #
    # (Arbitrary multi-key *sequences* — e.g. `g` then `g` — remain future work.
    # Per-event modifiers, produced text and auto-repeat ride on
    # `Event::Key#key_event` / `Tput::KeyEvent`.)
    property always_propagated_chars = Array(Char).new

    # Sets up IO listeners for keyboard and mouse input.
    def start_input
      # Ensure this surface is registered with an `Application`, the dispatcher
      # input is routed through. `#add` is idempotent — usually `Application#exec`
      # already registered us; standalone/reattach paths self-register here.
      (@application ||= Application.global).add self

      # Listen for keys/mouse on input. The read fiber lives on the device: it
      # parses bytes and routes each event up to the `Application` dispatcher.
      @screen.start_input

      # `start_input` only spawns the input fiber; that fiber puts the terminal
      # into raw (echo-off) mode as its first action, before its first blocking
      # read. Until then the tty is still in cooked mode and echoes everything.
      # Enabling mouse reporting now would make pointer movement during startup
      # echo report sequences onto the screen. Yield once so the fiber reaches
      # its first read (raw mode established), then enable mouse reporting.
      Fiber.yield

      @screen.enable_mouse(focus: send_focus?)

      # Enable, by default, the input enhancements that are safe and universally
      # expected — after raw mode, like mouse, so enable sequences aren't echoed:
      #
      #   * keyboard-protocol escape-code disambiguation (Esc is instant,
      #     Tab/Ctrl+I etc. distinguishable via `key_event`), which projects back
      #     onto legacy `key`/`char` so the event stream is unchanged.
      #   * bracketed paste — a paste arrives as `Event::Paste` instead of being
      #     interpreted as keystrokes.
      #
      # Both are no-ops on unsupported terminals. Modifier/release reporting
      # (`enable_keyboard_protocol(level: :events)`) stays opt-in, since it changes
      # the event stream.
      #
      # Only negotiate with a real terminal — writing enable sequences to a
      # pipe/file would corrupt the output stream.
      out = tput.output
      if out.responds_to?(:tty?) && out.tty?
        enable_keyboard_protocol
        enable_bracketed_paste

        # In-band resize (DEC 2048): enable when the terminal advertises support
        # (via DECRQM). When active, the SIGWINCH-driven path stands down and
        # resize reports arrive through the input stream instead, but both
        # funnel into the same `Event::Resize`.
        enable_in_band_resize if tput.features.in_band_resize?
      end

      # TODO Listen for resize on the output IO, if per-IO resize events ever
      # become possible.
    end

    # The input-mode toggles (keyboard-protocol / bracketed-paste /
    # in-band-resize / color-scheme) and their `*_enabled?` flags live on the
    # device (`Screen`), as does the OSC escape-sequence transport (`copy` /
    # `request_clipboard`, `report_cwd`, `progress`); this surface delegates them.

    # Demuxes one parsed input event (`Tput::InputEvent`) into the right Crysterm
    # event on this surface. Mouse reports go through the unified mouse path; a
    # paste becomes `Event::Paste`; in-band resize feeds the same debounced path
    # as SIGWINCH; everything else is a key transition — a release (only seen
    # when event reporting is enabled) becomes `Event::KeyRelease` so
    # `Event::KeyPress` always means a press, with the base `Event::Key` also
    # emitted for listeners that want every transition.
    #
    # :nodoc:
    def handle_input(e : Tput::InputEvent) : Crysterm::Event::KeyPress?
      if m = e.mouse
        dispatch_mouse m
      elsif pasted = e.paste
        # Route the paste to the focused widget and up its parent chain until a
        # handler `#accept`s it — literally the same walk a key press takes
        # (`#each_focus_chain`) — so the focused text field / terminal receives
        # it. Only unaccepted does it fall back to the window-level emit, for
        # app-level listeners.
        ev = Crysterm::Event::Paste.new pasted
        each_focus_chain do |el2|
          # A disabled widget does not react to a paste, but the paste still
          # propagates up to its (possibly enabled) ancestors. No handler-count
          # pre-check: `emit` has its own zero-cost fast path, and a guard here
          # would suppress `AnyEvent` listeners on the widget.
          el2.emit ev unless el2.disabled?
          break if ev.accepted?
        end
        emit ev unless ev.accepted?
      elsif clip = e.clipboard
        # OSC-52 clipboard read reply (answer to `request_clipboard`). Refresh
        # the app-wide clipboard mirror before notifying listeners, so a handler
        # reading `application.clipboard.text` sees the fresh value.
        application.try &.clipboard.refresh_from_terminal(clip)
        emit Crysterm::Event::ClipboardChanged.new clip
      elsif scheme = e.color_scheme
        emit Crysterm::Event::ColorSchemeChanged.new scheme
      elsif r = e.resize
        if r.cols > 0 && r.rows > 0
          # Report carries new size in pixels (0 when unknown); refresh cell
          # geometry directly from it, no ioctl/escape round-trip.
          @screen.apply_cell_pixels(r.pixel_width // r.cols, r.pixel_height // r.rows)
          # Hand the authoritative cell size to the debounced `#refresh_size`
          # path instead of re-probing via the `TIOCGWINSZ` ioctl that in-band
          # resize (DEC 2048) exists to bypass.
          @pending_inband_size = {r.cols, r.rows}
        end
        schedule_resize
      elsif e.release?
        emit_key_transition Crysterm::Event::KeyRelease.new e.char, e.key, e.sequence, e.key_event
      else
        # Return the emitted `KeyPress` so the caller can apply the default quit
        # keys as a *fallback*, only when no widget/handler `#accept`ed the key.
        press = Crysterm::Event::KeyPress.new e.char, e.key, e.sequence, e.key_event
        emit_key_transition press
        return press
      end
      nil
    end

    # Yields the focused widget, then each of its ancestors up to the toplevel —
    # the bubbling path an input event takes when it is offered to the focused
    # widget first and then to whoever encloses it. A no-op when nothing is
    # focused; `break` out of the block to stop the ascent (which is how a
    # consumer signals the event was handled).
    #
    # The per-widget gate (does this widget want a paste? is it keyable?) and the
    # stop condition belong in the caller's block, since they differ per event
    # kind; only the walk is shared. There is no `is_a? Widget` test: both
    # `#focused` and `Widget#parent` are already `Widget?`.
    private def each_focus_chain(& : Widget ->) : Nil
      el = focused
      while el
        yield el
        el = el.parent
      end
    end

    # Emits a key-transition event (`KeyPress`/`KeyRelease`) followed by the
    # generic `Event::Key` fan-out when anyone is listening for it.
    private def emit_key_transition(ev) : Nil
      emit ev
      emit Crysterm::Event::Key, ev if has_handlers?(Crysterm::Event::Key)
    end

    # Registers `el` as a widget that wants to receive keyboard input. Once
    # registered, the general key listener dispatches key presses to it, and it
    # participates in keyboard focus navigation.
    #
    # Widgets do not need to call this themselves: `Widget#initialize`
    # registers them automatically when they ask for keys (`#keys?`/`#input?`).
    def register_keyable(el : Widget)
      el.keyable = true if register_in el, @keyable
    end

    # Adds *el* to input-registry *coll* if not already present, returning whether
    # it was newly added — so the caller can run its one-time side effects (set
    # the widget's intrinsic flag, enable mouse reporting) only on first
    # registration.
    private def register_in(el : Widget, coll : Array(Widget)) : Bool
      return false if coll.includes? el
      coll.push el
      true
    end

    # Removes *el* from the keyboard registry only — the exact counterpart of
    # `#register_keyable`, used when a widget's focus policy drops to `None`.
    # (`#unregister` below drops keyboard AND mouse for a whole subtree.)
    def unregister_keyable(el : Widget)
      @keyable.delete el
    end

    # Removes `el` and its entire subtree from this window's keyboard and mouse
    # registries — the counterpart to `#register_keyable`/`#register_clickable`.
    # Without it the lists grow unboundedly, pinning every widget ever inserted,
    # and `@keyable` keeps handing detached entries to the focus navigation.
    #
    # The whole subtree goes, because removing a container also detaches its
    # descendants. Each widget's intrinsic `keyable?`/`clickable?` flag is left
    # alone: it records that the widget *wants* keys/mouse, so a later
    # re-`insert` re-registers it. `Array#delete` is by value and a no-op when
    # absent, so unregistering a never-registered widget is safe.
    def unregister(el : Widget)
      el.self_and_each_descendant do |e|
        @keyable.delete e
        @clickable.delete e
      end
    end

    # Sets up the general, screen-level key listener. It receives every
    # `Event::KeyPress` and dispatches it to the focused widget and up its
    # parent tree (until one `#accept`s it). Installed once per screen.
    private def _listen_keys
      return if @_listening_keys
      @_listening_keys = true

      on(Crysterm::Event::KeyPress) do |e|
        # Keyboard drag-and-drop sensor: Space lifts a focused draggable widget,
        # then Tab/arrows/Space/Escape drive the in-flight drag. Handled before
        # anything else so a drag fully owns the keyboard while it is in flight.
        next if drag_key_handled? e

        # Whether this key is on either always-propagate list (special `#key` or
        # ordinary `#char`) — scanned once and reused across the three checks
        # below.
        always_propagate = @always_propagated_keys.includes?(e.key) ||
                           @always_propagated_chars.includes?(e.char)

        # Not propagating and key isn't on the always-propagate list: done.
        if !@propagate_keys && !always_propagate
          next
        end

        # A handler installed before this one (this listener is installed in
        # the Window constructor, so only internal ones can precede it) may
        # have consumed the key already.
        next if e.accepted?

        # Pass the key press to the focused widget, then up the parent tree
        # until someone `#accept`s it; drop it if it reaches the toplevel
        # unhandled.
        #
        # When a widget has grabbed keys (e.g. a text edit reading input), the
        # key goes to the focused widget ONLY: typing `j`/`k` into a text field
        # inside a `vi_keys:`-enabled `Form` must not both insert the character and
        # trigger the form's navigation. `always_propagate` keys (Tab, etc.) are
        # the deliberate exception: they still bubble so the form can navigate.
        grabbed = @grab_keys && !always_propagate

        each_focus_chain do |el2|
          # A disabled widget does not react to keys, but keys still
          # propagate up to its (possibly enabled) ancestors.
          if el2.keyable? && !el2.disabled?
            emit_key el2, e
          end

          break if e.accepted?

          # Stop at the focused widget while keys are grabbed.
          break if grabbed
        end

        # Default focus navigation: if no widget consumed the key, `Tab`/
        # `Shift+Tab` move focus to the next/previous focusable widget. Opt out
        # per-screen via `tab_navigation = false`.
        if @tab_navigation && !e.accepted?
          case e.key
          when Tput::Key::Tab
            e.accept
            focus_next
            update
          when Tput::Key::ShiftTab
            e.accept
            focus_previous
            update
          end
        end

        # Chrome-region navigation (see `window_region_focus.cr`): F6/Shift+F6
        # cycle focus between the chrome bars (menu/tool/status) and the
        # central area; Escape returns from a bar to the central area. Legacy
        # terminals report Shift+F6 as F18 (shifted F-keys are offset by 12);
        # enhanced-protocol terminals report F6 with the shift modifier.
        if @region_navigation && !e.accepted?
          case
          when e.key == Tput::Key::F6 && !e.shift?
            e.accept
            focus_region_next
            update
          when e.key == Tput::Key::F18 || (e.key == Tput::Key::F6 && e.shift?)
            e.accept
            focus_region_previous
            update
          when e.key == Tput::Key::Escape && region_of(focused)
            e.accept
            focus_central
            update
          end
        end
      end
    end

    # Emits an Event::KeyPress as usual, plus the base `Event::Key` for
    # listeners that want every transition, plus an event for the individual key
    # if any — so listeners can listen directly for e.g. `Event::KeyPress::CtrlP`
    # instead of checking `#key` on the generic event.
    @[AlwaysInline]
    def emit_key(el, e : Event)
      # No handler-count pre-check on the generic emit: `emit` has its own
      # zero-cost fast path, and a guard here would suppress `AnyEvent`
      # listeners on the widget.
      el.emit e
      # The base-class fan-out `Window#emit_key_transition` does for the window,
      # per the subscription menu documented on `Event::Key`. Guarded: an
      # `AnyEvent` listener already saw `e` above, so the guard only skips a
      # duplicate delivery, never information.
      if e.is_a?(Crysterm::Event::Key) && el.has_handlers?(Crysterm::Event::Key)
        el.emit Crysterm::Event::Key, e
      end
      if e.key
        Crysterm::Event::KeyPress::KEYS[e.key]?.try do |keycls|
          # Guarded so a keypress doesn't allocate a per-key event nobody
          # subscribed to; `AnyEvent` listeners already received `e` above.
          if el.has_handlers?(keycls)
            # Forward `key_event` so the specific-key event carries the same
            # enhanced-protocol info (modifiers, repeat, codepoint) as `e`, and
            # propagate a handler's `accept` back onto `e` so the shared
            # propagation loop actually stops the key.
            ke = keycls.new e.char, e.key, e.sequence, e.key_event
            el.emit ke
            e.accept if ke.accepted?
          end
        end
      end
    end
  end
end
