require "event_handler"
require "term-screen"
require "tput"
require "log"

require "./macros"
require "./methods"
require "./widget/node"
require "./widget/*"

module Crysterm

  class Application
    ##include EventHandler
    include Methods
    include Macros
    include EventHandler

    class_getter! global : self?
    @@total = 0
    class_getter instances = [] of self
    @@_bound = false

    property _exiting = false

    # wth?
    property x = 0
    property y = 0

    property input : IO
    property output : IO
    #@log : Bool
    @type = :application
    @index : Int32 = -1 # -1 so that assignments start from 0
    property use_buffer : Bool # useBuffer
    property resize_timeout : Time::Span

    #getter terminfo : Unibilium::Terminfo?
    getter! tput : ::Tput

    property hide_cursor_old : Bool = false

    @_tput_set_up = false

    getter is_alt = false

    getter _title : String?

    getter cursor_hidden = false
    record CursorState, x : Int32, y : Int32, hidden : Bool

    @saved = {} of String => CursorState

    @ret = false

    @exiting = false

    getter _buf : String? = nil

    @x : Int32 = 0
    @y : Int32 = 0
    @saved_x : Int32 = 0
    @saved_y : Int32 = 0

    @dump = true

    @_listened_keys : Bool = false

    def initialize(
      @input = STDIN.dup,
      @output = STDOUT.dup,
      @log = ::Log.for(self.class),
      @use_buffer = true,
      @force_unicode = false,
      @resize_timeout = 0.3.seconds,
      terminfo : Bool | Unibilium::Terminfo = true,
      @dump=true,
      @term = ENV["TERM"]? || "{% if flag?(:windows) %}windows-ansi{% else %}xterm{% end %}",
    )

      @x = 0
      @y = 0
      @saved_x = 0
      @saved_y = 0

      # TODO make these check @output, not STDOUT which is probably used.
      @cols = ::Term::Screen.cols || 1
      @rows = ::Term::Screen.rows || 1

      # TODO. This doesn't work now that i/o isn't subclass.
      #if @dump
      #  @input.on(DataEvent) { |d|
      #    Log.info { p d }
      #  }
      #  @output.on(DataEvent) { |d|
      #    Log.info { p d }
      #  }
      #end

      # XXX This is just name of term. Run terminfo init,
      # then read this from there, not here.
      #@_terminal = terminal.downcase

      bind

      @tput = setup_tput terminfo

      listen
    end

    def bind
      @@global = self unless @@global

      unless @@instances.includes? self
        @@instances << self
        @index = @@total
        @@total += 1
      end

      return if @@_bound
      @@_bound = true

      at_exit {
        Crysterm::Application.instances.each do |app|
          # XXX Do we restore window title ourselves?
          #if app._original_title
          #  app.tput.set_title(...)
          #end

          app.tput.flush
          app._exiting = true
        end
      }
    end

    def setup_tput(terminfo : Bool | Unibilium::Terminfo = true)
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
          # TODO these options
          #term: @term,
          #padding: @padding,
          #extended: @extended,
          #termcap: @termcap,
          use_buffer: @use_buffer,
          force_unicode: @force_unicode
        )

        # TODO tput stuff till end of function
      end
      @tput
    end

    def pause
      lsave_cursor "pause"
      normal_buffer if is_alt
      show_cursor

      #disable_mouse if mouse_enabled
    end

    def resume
      if responds_to? :_resume
        _resume
      end
    end


    def title=(title)
      set_title title
    end

    def listen
      # Potentially reset window title on exit:
      #if !rxvt?
      #  if (!vte?)
      #    set_title_mode_feature 3
      #  end
      #  manipulate_window(21) { |err, data|
      #    return if err
      #    @_original_title = data.text
      #  }
      #end

      # Listen for keys/mouse on input
      #if (@input._our_input == 0)
      #  @input._out_input = 1;
        _listen_keys
      #} else
      #  @input._our_input += 1
      #end

      #on(AddHandlerEvent) do |wrapper|
      #  if wrapper.event.is_a?(KeyPressEvent) # or MouseEvent
      #    # remove self...
      #    if (@input.set_raw_mode && !@input.raw?)
      #      @input.set_raw_mode true
      #      @input.resume
      #    end
      #  end
      #end
      #on(AddHandlerEvent) do |wrapper|
      #  if (wrapper.is_a? MouseEvent)
      #    off(AddHandlerEvent, self)
      #    bind_mouse
      #  end
      #end
      # Listen for resize on output
      #if (@output._our_output==0)
      #  @output._our_output = 1
      #  _listen_output
      #else
      #  @output._our_output += 1
      #end
    end

    def _listen_keys
      return if @_listened_keys
      @_listened_keys = true
      spawn do
        tput.listen do |char, key, sequence|
          @@instances.each do |app|
            next if app.input != @input
            emit KeyPressEvent.new char, key, sequence
            # TODO - possibly also:
            #emit Key(Name)_Event...
          end
        end
      end
    end

    def destroy
      if @@instances.delete self
        tput.flush
        @_exiting = true

        if @@instances.any?
          @@global = @@instances[0]
        else
          @@global = nil
          # TODO remove all signal handlers set up on the app's process
          @@_bound = false
        end

        # XXX reset terminal back to usable

        @destroyed = true
        emit DestroyEvent
      end
    end

  end
end
