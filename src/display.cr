require "mutex"

require "event_handler"

require "./mixin/instances"

module Crysterm
  # A physical display managed by Crysterm. Can be created on anything that is an IO.
  #
  # If a `Display` object is not explicitly created, its creation will be
  # implicitly performed at the time of creation of first `Screen`.
  class Display
    include EventHandler

    include Mixin::Instances

    # :nodoc: Flag indicating whether at least one `Display` has called `#bind`.
    # Can potentially be removed; it appears only in this file.
    # @@_bound = false
    # XXX Currently disabled to remove it over time if it appears not needed.

    # Force Unicode (UTF-8) even if auto-detection did not discover terminal support for it?
    property? force_unicode = false

    # Input IO
    property input : IO::FileDescriptor = STDIN.dup

    # Output IO
    property output : IO::FileDescriptor = STDOUT.dup

    # Access to instance of `Tput`, used for affecting the terminal/IO.
    getter tput : ::Tput

    # :nodoc: Pointer to Fiber which is listening for keys, if any
    @_listened_keys : Fiber?

    # `Display`'s general-purpose `Mutex`
    @mutex = Mutex.new

    def initialize(
      input = STDIN.dup,
      output = STDOUT.dup,
      @use_buffer = false,
      @force_unicode = false,
      terminfo : Bool | Unibilium::Terminfo = true,
      @term = ENV["TERM"]? || "{% if flag?(:windows) %}windows-ansi{% else %}xterm{% end %}"
    )
      # TODO make these check @output, not STDOUT which is probably used.
      @cols = ::Term::Screen.cols || 1
      @rows = ::Term::Screen.rows || 1

      @terminfo = case terminfo
                  when true
                    Unibilium::Terminfo.from_env
                  when false
                    nil
                  when Unibilium::Terminfo
                    terminfo.as Unibilium::Terminfo
                  end

      @tput = ::Tput.new(
        terminfo: @terminfo,
        input: input,
        output: output,
        # TODO these options
        # term: @term,
        # padding: @padding,
        # extended: @extended,
        # termcap: @termcap,
        use_buffer: @use_buffer,
        force_unicode: @force_unicode
      )

      @mutex.synchronize do
        unless @@instances.includes? self
          @@instances << self
          # return if @@_bound
          # @@_bound = true
          # ... Can do anything else here, which will execute only for first
          # display created in the program
        end
      end

      listen
    end

    # Default application title, propagated as a default to `Screen`s
    property title : String? = nil

    # Displays the main screen, set up IO hooks, and starts the main loop.
    #
    # This is similar to how it is done in the Qt framework.
    #
    # This function will render the specified `screen` or global `Screen`.
    #
    # Note that if using multiple `Display`s, currently you should provide
    # `screen` argument explicitly or otherwise every `Display#exec` would
    # run the same/default screen.
    def exec(screen : Crysterm::Screen? = nil)
      if w = screen || Crysterm::Screen.global
        w.render
      else
        # XXX This part might be changed in the future, if we allow running line-
        # rather than screen-based apps, or if we allow something headless.
        raise Exception.new "No Screen exists, there is nothing to render and run."
      end

      listen

      # The main loop is currently just a sleep :)
      sleep
    end

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
      _listen_keys
      # _listen_mouse # TODO
      # else
      #  @tput.input._our_input += 1
      # end

      # TODO Do this, if it's possible to get resize events on individual IOs.
      # Listen for resize on output
      # if (@output._our_output==0)
      #  @output._our_output = 1
      #  _listen_output
      # else
      #  @output._our_output += 1
      # end
    end

    # Starts emitting `Event::KeyPress` events on key presses.
    #
    # NOTE Keys are listened for in a separate `Fiber`.
    # The code tries passively to ensure at most one fiber per display is listening.
    def _listen_keys
      @mutex.synchronize {
        return if @_listened_keys
        @_listened_keys = spawn {
          tput.listen do |char, key, sequence|
            emit Crysterm::Event::KeyPress.new char, key, sequence
          end
        }
      }
    end

    # Destroys current `Display`.
    def destroy
      Screen.instances.select(&.display.==(self)).each do |s|
        # s.leave # Done in screen's destroy
        s.destroy
      end

      super

      # TODO Don't do this unconditionally, but return to whatever
      # state it was before.
      @input.cooked!
    end
  end
end
