require "event_handler"

module Crysterm
  # Crysterm application. All apps begin by instantiating or subclassing this class.
  #
  # If an `App` object is not explicitly created, its creation will be
  # implicitly performed at the time of creation of first `Screen`.
  class App
    include EventHandler # Event model

    # List of existing instances.
    #
    # For automatic management of this list, make sure that `#bind` is called at
    # creation of `App`s and that `#destroy` is called at termination.
    #
    # `#bind` does not have to be called explicitly because it happens during `#initialize`.
    # `#destroy` does need to be called, and if/when calling `#destroy` results in no `App`s
    # remaining, program will exit.
    class_getter instances = [] of self

    # Returns number of created `App` instances
    def self.total
      @@instances.size
    end

    # Creates and/or returns the "global" (first) instance of `App`.
    #
    # An alternative approach, which is currently not implemented, would be to hold the global `App`
    # in a class variable, and return it here. In that way, the choice of the default/global `App`
    # would be configurable in runtime.
    def self.global(create = true)
      (instances[0]? || (create ? new : nil)).not_nil!
    end

    # Access to instance of `Tput`, used for affecting the terminal/IO.
    getter! tput : ::Tput
    # XXX Any way to succeed turning this into `getter` without `!`?

    # Force Unicode (UTF-8) even if auto-detection did not discover terminal support for it?
    property? force_unicode = false

    # Amount of time to wait before redrawing the screen, after the terminal resize event is received.
    #
    # The default, and also the value used in Qt, is 0.3 seconds. An alternative setting used in console
    # apps is 0.2 seconds.
    property resize_timeout : Time::Span = 0.3.seconds

    # True if the `App` objects are being destroyed to exit program; otherwise returns false.
    # property? exiting : Bool = false

    # Default application title, inherited by `Screen`s
    getter title : String? = nil

    # Input IO
    property input : IO::FileDescriptor = STDIN.dup

    # Output IO
    property output : IO::FileDescriptor = STDOUT.dup

    # :nodoc:
    @_listened_keys : Bool = false
    # XXX groom this

    # :nodoc: Flag indicating whether at least one `App` has called `#bind`.
    @@_bound = false

    def initialize(
      input = STDIN.dup,
      output = STDOUT.dup,
      @use_buffer = false,
      @force_unicode = false,
      resize_timeout : Time::Span? = nil,
      terminfo : Bool | Unibilium::Terminfo = true,
      @term = ENV["TERM"]? || "{% if flag?(:windows) %}windows-ansi{% else %}xterm{% end %}"
    )
      resize_timeout.try { |v| @resize_timeout = v }

      # TODO make these check @output, not STDOUT which is probably used.
      @cols = ::Term::Screen.cols || 1
      @rows = ::Term::Screen.rows || 1

      @tput = setup_tput input, output, terminfo

      bind

      listen
    end

    # Registers an `App`. Happens automatically during `initialize`; generally not used directly.
    def bind
      @@instances << self unless @@instances.includes? self

      return if @@_bound
      @@_bound = true
    end

    def setup_tput(input : IO, output : IO, terminfo : Bool | Unibilium::Terminfo = true)
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

      # TODO tput stuff till end of function

      @tput
    end

    # Sets title locally and in the terminal's window bar when possible
    def title=(@title)
      @tput.title = @title
    end

    def listen
      # Potentially reset window title on exit:
      # if !rxvt?
      #  if !vte?
      #    set_title_mode_feature 3
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
      # _listen_mouse
      # else
      #  @tput.input._our_input += 1
      # end

      # on(AddHandlerEvent) do |wrapper|
      #  if wrapper.event.is_a?(Event::KeyPress) # or Event::Mouse
      #    # remove self...
      #    if (@tput.input.set_raw_mode && !@tput.input.raw?)
      #      @tput.input.set_raw_mode true
      #      @tput.input.resume
      #    end
      #  end
      # end
      # on(AddHandlerEvent) do |wrapper|
      #  if (wrapper.is_a? Event::Mouse)
      #    off(AddHandlerEvent, self)
      #    bind_mouse
      #  end
      # end
      # Listen for resize on output
      # if (@output._our_output==0)
      #  @output._our_output = 1
      #  _listen_output
      # else
      #  @output._our_output += 1
      # end
    end

    def _listen_keys
      return if @_listened_keys
      @_listened_keys = true
      spawn do
        tput.listen do |char, key, sequence|
          @@instances.each do |app|
            # XXX What to do here -- i/o has been removed from this class.
            # It only exists in tput, so how to check/compare?
            # Do we need to add it back in?
            # next if app.input != @tput.input

            emit Crysterm::Event::KeyPress.new char, key, sequence
          end
        end
      end
    end

    # Runs the app and starts main loop.
    #
    # This is similar to how it is done in the Qt framework.
    #
    # This function will render the specified `screen` or global `Screen`.
    def exec(screen : Crysterm::Screen? = nil)
      if s = screen || Crysterm::Screen.global
        s.render
      else
        # XXX This part might be changed in the future, if we allow running line-
        # rather than screen-based apps, or if we allow something headless.
        raise Exception.new "No Screen exists, there is nothing to render and run."
      end

      sleep
    end

    # Destroys current `App`
    def destroy
      Screen.instances.each &.destroy
      @@instances.delete self
      @destroyed = true
      emit Crysterm::Event::Destroy
    end
  end
end

# TODO
# application:
# cursor.flash.time, double.click.interval,
# keyboard.input.interval, start.drag.distance,
# start.drag.time,
# stylesheet -> string
# wheelscrolllines
# close.all.windows, active.modal.window, active.popup.window
# active.window, alert(), all_widgets
# Event::AboutToQuit
# ability to set terminal font
# something about effects
# NavigationMode
# palette?
# set.active.screen
