require "event_handler"
require "term-screen"
require "tput"
require "log"

require "./macros"
require "./core_application"
require "./methods"
require "./widget/node"
require "./widget/*"

module Crysterm
  class Application < CoreApplication
    # #include EventHandler
    include Methods
    include Macros
    include EventHandler

    class_getter instances = [] of self

    def self.total
      @@instances.size
    end

    def self.global
      instances[0]?.not_nil!
    end

    @@_bound = false

    property _exiting = false

    @index : Int32 = -1 # -1 so that assignments start from 0

    # Amount of time to wait before redrawing the screen, after the
    # terminal resize event is received.
    property resize_timeout : Time::Span

    # Force Unicode (UTF-8) even if auto-detection did not discover
    # terminal support for it?
    property force_unicode = false

    # getter terminfo : Unibilium::Terminfo?

    # Tput object.
    getter! tput : ::Tput

    @_tput_set_up = false

    getter _title : String?

    @_listened_keys : Bool = false

    # Automatically display SIP when entering widgets that accept keyboard input.
    property? auto_sip_enabled : Bool = true

    # TODO
    # application:
    #cursor.flash.time, double.click.interval,
    # keyboard.input.interval, start.drag.distance,
    # start.drag.time,
    #stylesheet -> string
    # wheelscrolllines
    #close.all.windows, active.modal.window, active.popup.window
    # active.window, alert(), all_widgets
    # AboutToQuitEvent
    #ability to set terminal font
    #something about effects
    #NavigationMode
    #palette?
    #set.active.screen

    def initialize(
      input = STDIN.dup,
      output = STDOUT.dup,
      @log = ::Log.for(self.class),
      @use_buffer = false,
      @force_unicode = false,
      @resize_timeout = 0.3.seconds,
      terminfo : Bool | Unibilium::Terminfo = true,
      @term = ENV["TERM"]? || "{% if flag?(:windows) %}windows-ansi{% else %}xterm{% end %}"
    )
      # TODO make these check @output, not STDOUT which is probably used.
      @cols = ::Term::Screen.cols || 1
      @rows = ::Term::Screen.rows || 1

      bind

      @tput = setup_tput input, output, terminfo

      listen
    end

    def bind
      @@global = self unless @@global

      @@instances << self # unless @@instances.includes? self

      return if @@_bound
      @@_bound = true

      at_exit do
        # XXX Should these completely separate loops somehow
        # be rearranged and/or combined more nicely?

        Crysterm::Application.instances.each do |app|
          # XXX Do we restore window title ourselves?
          # if app._original_title
          #  app.tput.set_title(...)
          # end

          app.tput.flush
          app.tput._exiting = true
        end

        Crysterm::Screen.instances.each do |screen|
          screen.destroy
        end
      end
    end

    def setup_tput(input : IO, output : IO, terminfo : Bool | Unibilium::Terminfo = true)
      unless @_tput_set_up
        @_tput_set_up = true

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
      end
      @tput
    end

    def title=(title)
      set_title title
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
      #  if wrapper.event.is_a?(KeyPressEvent) # or MouseEvent
      #    # remove self...
      #    if (@tput.input.set_raw_mode && !@tput.input.raw?)
      #      @tput.input.set_raw_mode true
      #      @tput.input.resume
      #    end
      #  end
      # end
      # on(AddHandlerEvent) do |wrapper|
      #  if (wrapper.is_a? MouseEvent)
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

            emit KeyPressEvent.new char, key, sequence
            # TODO - possibly also:
            # if key
            #   emit key_event[key].new char, key, sequence
            # end
            # But this requires a file with mappings of:
            # key enums value => key event class
            # It does seem more convenient for the users than
            # listening for all keys in their code though...
          end
        end
      end
    end

    def destroy
      if @@instances.delete self
        tput.flush
        tput._exiting = true

        if @@instances.any?
          @@global = @@instances[0]
        else
          @@global = nil
          # TODO remove all signal handlers set up on the app's process
          # Primarily, exit handler
          @@_bound = false
        end

        # TODO rest of stuf; e.g. reset terminal back to usable

        @destroyed = true
        emit DestroyEvent
      end
    end

    def about_crysterm
      "Crysterm v#{Crysterm::VERSION}, Tput v#{Tput::VERSION}"
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
