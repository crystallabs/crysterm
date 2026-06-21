module Crysterm
  class Screen
    # File related to interaction on the display

    # Is the focused element grab and receiving all keypresses?
    property? grab_keys : Bool = Config.screen_grab_keys

    # Are keypresses being propagated further, or (except ignored ones) not propagated?
    property? propagate_keys : Bool = Config.screen_propagate_keys

    # Should the constructor install a default quit handler? When on, pressing
    # `q` (or Ctrl-Q) destroys the screen and exits the program — the behavior
    # every demo used to wire up by hand. Apps that bind those keys themselves
    # can turn it off globally via the `screen.default_quit_keys` config option
    # or per-screen via `default_quit_keys: false`.
    property? default_quit_keys : Bool = Config.screen_default_quit_keys

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
      listen_mouse
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
          tput.listen do |char, key, sequence, mouse|
            # The same input fiber feeds both keyboard and (terminal) mouse: a
            # parsed mouse report is dispatched through the unified mouse path;
            # everything else is announced as a key press.
            if mouse
              dispatch_mouse mouse
            else
              emit Crysterm::Event::KeyPress.new char, key, sequence
            end
          end
        rescue
        end
      }
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
        # When a widget has grabbed keys (e.g. a `TextArea`/`TextBox` reading
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
