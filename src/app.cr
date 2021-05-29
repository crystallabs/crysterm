module Crysterm
  # Main Crysterm class. All applications begin by instantiating or subclassing this class.
  class App
    include EventHandler # Event model

    # Name of the app. If unset, defaults to the path of the currently running program.
    property app_name : String = Process.executable_path || PROGRAM_NAME

    # App version. If unset, defaults to Crystal app's VERSION string.
    property app_version : String = VERSION

    # Internet domain of the organization that wrote this app.
    property organization_domain : String = ""

    # Name of the organization that wrote this app. If unset, defaults to organization's internet domain.
    property organization_name : String { @organization_domain }

    class_getter instances = [] of self

    # Tput object. XXX Any way to succeed turning this into `getter` without `!`?
    getter! tput : ::Tput

    # Force Unicode (UTF-8) even if auto-detection did not discover terminal support for it?
    property force_unicode = false

    # Amount of time to wait before redrawing the screen, after the terminal resize event is received.
    property resize_timeout : Time::Span

    @_listened_keys : Bool = false

    # Returns number of `App` instances
    def self.total
      @@instances.size
    end

    # Creates and/or returns the "global" (by default the first) instance of `App`
    def self.global(create = true)
      ( instances[0]? || (create ? new : nil)).not_nil!
    end

    @@_bound = false

    # Registers an `App`. Happens automatically during `initialize`; generally not used directly.
    def bind
      @@global = self unless @@global

      @@instances << self # unless @@instances.includes? self

      return if @@_bound
      @@_bound = true

      at_exit do
        # XXX Should these completely separate loops somehow
        # be rearranged and/or combined more nicely? Is defining this
        # per each App instance that calls bind even OK?

        self.class.instances.each do |app|
          # XXX Do we restore window title ourselves?
          # if app._original_title
          #  app.tput.set_title(...)
          # end

          app.tput.try do |tput|
            tput.flush
            tput._exiting = true
          end
        end

        # XXX Probably shouldn't be done here, but via regular methods
        #Crysterm::Screen.instances.each do |screen|
        #  screen.destroy
        #end
      end
    end

    # Runs the app, similar to how it is done in the Qt framework.
    def exec(screen : Crysterm::Screen? = nil)
      (screen || Crysterm::Screen.global(true)).render
      sleep
    end

    # Destroys an `App` instance
    def destroy
      if @@instances.delete self
        tput.try do |tput|
          tput.flush
          tput._exiting = true
        end

        if @@instances.any?
          @@global = @@instances[0]
        else
          @@global = nil
          # TODO remove all signal handlers set up on the app's process
          # Primarily, exit handler
          @@_bound = false
        end

        # TODO rest of stuff; e.g. reset terminal back to usable

        @destroyed = true
        emit Crysterm::Event::Destroy

        if Screen.instances.empty?
          @input.cooked! # XXX This is maybe to basic of a "return to previous state" method.
          exit
        end
      end
    end

    # Returns true if the app objects are being destroyed; otherwise returns false.
    property? exiting : Bool = false
    # XXX Is this an alias with `closing_down?`

    # XXX Is there a difference between `exiting` and `_exiting`, or those are the same? Adjust if needed.
    property? _exiting = false

    # End of stuff related to multiple instances

    # XXX Save/restore all state here. What else? Stop main loop etc.?
    def quit
      @exiting = true
    end

    # Current application title
    #
    # This value is dependent on the state of the application; title may vary during execution.
    # The value is returned from the local variable; it is not read from the terminal window's title.
    getter title : String? = nil

    property input : IO::FileDescriptor = STDIN.dup

    property output : IO::FileDescriptor = STDOUT.dup

    # Sets title locally and in the terminal's window bar when possible
    def title=(@title)
      @tput.title = @title
    end

    def initialize(
      input = STDIN.dup,
      output = STDOUT.dup,
      @use_buffer = false,
      @force_unicode = false,
      @resize_timeout = 0.3.seconds,
      terminfo : Bool | Unibilium::Terminfo = true,
      @term = ENV["TERM"]? || "{% if flag?(:windows) %}windows-ansi{% else %}xterm{% end %}"
    )
      # TODO make these check @output, not STDOUT which is probably used.
      @cols = ::Term::Screen.cols || 1
      @rows = ::Term::Screen.rows || 1

      @tput = setup_tput input, output, terminfo

      bind

      listen
    end

    # XXX Btw question, do we want to emit events from anywhere (like now), or we want to dedicate a queue/channel through which they're emitted?

    def self.about
      "Crysterm #{Crysterm::VERSION}, Tput #{::Tput::VERSION}"
    end

    def about
      "#{@app_name} #{@app_version}"
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

    # We can't name the function 'out'. But it is here for reference only.
    # To print to a temporary buffer rather than @output, initialize
    # @tput.ret to an IO. Then all writes will go there instead of to @output.
    # While @tput.ret is nil, output goes to output as usual.
    # NOTE Check how does this affect behavior with the local @_buf element.
    # def out
    # end

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
