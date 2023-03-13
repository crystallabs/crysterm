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

    # Force Unicode (UTF-8) even if auto-detection did not discover terminal support for it?
    property? force_unicode = false

    # Input IO
    property input : IO = STDIN.dup

    # Output IO
    property output : IO = STDOUT.dup

    # Error IO. (Could be used for redirecting error output to a particular widget)
    property error : IO = STDERR.dup

    # Access to instance of `Tput`, used for generating term control sequences.
    getter tput : ::Tput

    # :nodoc: Pointer to Fiber which is listening for keys, if any
    @_listening_keys : Fiber?

    # `Display`'s general-purpose `Mutex`
    @mutex = Mutex.new

    def initialize(
      @input = @input,
      @output = @output,
      @error = @error,
      *,
      @use_buffer = false,
      @force_unicode = @force_unicode,
      terminfo : Bool | Unibilium::Terminfo = true,
      @term = ENV["TERM"]? || "{% if flag?(:windows) %}windows-ansi{% else %}xterm{% end %}"
    )
      # TODO make these check @output, not STDOUT which is probably used.
      # TODO Also see how urwid does the size check
      @width = ::Term::Screen.cols || 1
      @height = ::Term::Screen.rows || 1

      @terminfo = case terminfo
                  when true
                    Unibilium::Terminfo.from_env
                  when false
                    nil
                  when Unibilium::Terminfo
                    terminfo.as Unibilium::Terminfo
                  end

      # XXX Should `error` be used here in any way? (Probably not since we're not
      # initializing anything on the error output?)
      @tput = ::Tput.new(
        terminfo: @terminfo,
        input: @input,
        output: @output,
        # TODO activate these options if needed:
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
          # ... Can do anything else here, which will execute only for first
          # display created in the program
        end
      end

      listen
    end

    # Default application title, propagated as a default to contained `Screen`s
    property title : String? = nil

    # Displays the main screen, set up IO hooks, and starts the main loop.
    #
    # This is similar to how it is done in the Qt framework.
    #
    # This function will render the specified `screen`, the first `Screen` assigned to `Display`, or global `Screen` (in that order).
    #
    # Screen's display is forcibly set to the current display.
    #
    # Note that if using multiple `Display`s, you should probably provide `screen` argument explicitly or have at least one `Screen` added to every `Display`.
    # Otherwise it could happen that Displays take the same screen from each other.
    # run the same/default screen.
    def exec(screen : Crysterm::Screen? = nil)
      s = @mutex.synchronize do
        screen || Screen.instances.select(&.display.==(self)).try { |screens| screens.first } || Crysterm::Screen.global
      end

      s.display = self

      if s
        s.render
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
        return if @_listening_keys
        @_listening_keys = spawn {
          tput.listen do |char, key, sequence|
            emit Crysterm::Event::KeyPress.new char, key, sequence
          end
        }
      }
    end

    # Destroys current `Display`.
    def destroy
      @mutex.synchronize do
        Screen.instances.select(&.display.==(self)).each do |s|
          # s.leave # Done in screen's destroy
          s.destroy
        end

        super

        # TODO Don't do this unconditionally, but return to whatever
        # state it was before.
        @input.try { |i|
          if i.responds_to? :"cooked!"
            i.cooked!
          end
        }
      end
    end
  end
end
