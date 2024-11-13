module Crysterm
  class Screen
    # File related to interaction on the display

    # Is the focused element grab and receiving all keypresses?
    property? grab_keys = false

    # Are keypresses being propagated further, or (except ignored ones) not propagated?
    property? propagate_keys = true

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
      # listen_mouse # TODO
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
        tput.listen do |char, key, sequence|
          emit Crysterm::Event::KeyPress.new char, key, sequence
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

    # And this is for the other/alternative method where the screen
    # first gets the keys, then potentially passes onto children
    # elements.
    def _listen_keys(el : Widget? = nil)
      if el && !@keyable.includes? el
        el.keyable = true
        @keyable.push el
      end

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
        focused.try do |el2|
          while el2 && el2.is_a? Widget
            if el2.keyable?
              emit_key el2, e
            end

            if e.accepted?
              break
            end

            el2 = el2.parent
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
