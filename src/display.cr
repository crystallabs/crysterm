require "event_handler"

require "./event"
require "./mixin/instances"
require "./mixin/children"

require "./display_resize"
require "./display_interaction"

module Crysterm
  # A physical display managed by Crysterm. Can be created on anything that is an IO.
  #
  # If a `Display` object is not explicitly created, its creation will be
  # implicitly performed at the time of creation of first `Screen`.
  class Display
    include EventHandler
    include Mixin::Instances
    include Mixin::Children

    # Input IO
    property input : IO = STDIN.dup

    # Output IO
    property output : IO = STDOUT.dup

    # Error IO. (Could be used for redirecting error output to a particular widget)
    property error : IO = STDERR.dup

    # Force Unicode (UTF-8) even if terminfo auto-detection did not find support for it?
    property? force_unicode = false

    # Display's title, if/when applicable
    property title : String?

    # Display width
    # TODO make these check @output, not STDOUT which is probably used. Also see how urwid does the size check
    property width = 1

    # Display height
    # TODO make these check @output, not STDOUT which is probably used. Also see how urwid does the size check
    property height = 1

    # Access to instance of `Tput`, used for generating term control sequences.
    getter tput : ::Tput

    def initialize(
      @input = @input,
      @output = @output,
      @error = @error,
      @title = @title,
      *,
      @width = @width,
      @height = @height,
      @force_unicode = @force_unicode,
      @resize_interval = @resize_interval,

      terminfo : Bool | Unibilium::Terminfo = true

      # Not needed for now. Also better not to couple with terminal specifics
      # @term = ENV["TERM"]? || "{% if flag?(:windows) %}windows-ansi{% else %}xterm{% end %}"
      # @use_buffer = false,
    )
      terminfo = case terminfo
                 in true
                   Unibilium::Terminfo.from_env
                 in false, nil
                   nil
                 in Unibilium::Terminfo
                   terminfo.as Unibilium::Terminfo
                 end

      # XXX Should `error` fd be passed to tput as well?
      # (Probably not since we're not initializing anything on the error output?)
      @tput = ::Tput.new(
        terminfo: terminfo,
        input: @input,
        output: @output,
        force_unicode: @force_unicode,
        use_buffer: false,
      )
      # XXX Add those options too if needed:
      # term: @term,
      # padding: @padding,
      # extended: @extended,
      # termcap: @termcap,

      @_resize_fiber = Fiber.new "resize_loop" { resize_loop }

      # ## ### TODO Remove this block when display/screen are merged
      @@instances << self
      on(::Crysterm::Event::Resize) do |e|
        # XXX Display should have a list of Screens belonging to it. But until that happens
        # we'll find them manually.
        Screen.instances.select(&.display.==(self)).try { |screens|
          screens.each do |scr|
            scr.emit e
          end
        }
      end
      ### ###

      on ::Crysterm::Event::Attach, ->on_attach(::Crysterm::Event::Attach)
      on ::Crysterm::Event::Detach, ->on_detach(::Crysterm::Event::Detach)
      on ::Crysterm::Event::Destroy, ->on_destroy(::Crysterm::Event::Destroy)

      emit ::Crysterm::Event::Attach, self
    end

    def on_attach(e)
      @width = ::Term::Screen.cols || @width
      @height = ::Term::Screen.rows || @height

      # Push resize event to screens assigned to this display. We choose this approach
      # because it results in less links between the components (as opposed to pull model).
      @_resize_handler = GlobalEvents.on(::Crysterm::Event::Resize) do |e|
        schedule_resize
      end
    end

    def on_detach(e)
      @_resize_handler.try { |e| GlobalEvents.off ::Crysterm::Event::Resize, e }

      Screen.instances.select(&.display.==(self)).each do |s|
        # s.leave # No need, done as part of Screen#destroy
        s.destroy
      end

      # TODO Don't do this unconditionally, but return to whatever
      # state it was in before.
      @input.try { |i|
        if i.responds_to? :"cooked!"
          i.cooked!
        end
      }
    end

    # Destroys current `Display`.
    def on_destroy(e)
      on_detach(e)
    end

    # Displays the main screen, set up IO hooks, and starts the main loop.
    #
    # This is similar to how it is done in the Qt framework.
    #
    # This function will render the specified `screen` or the first `Screen` assigned to `Display`.
    def exec(screen : Crysterm::Screen? = nil)
      emit ::Crysterm::Event::Attach, self

      s = screen || Screen.instances.select(&.display.==(self)).try { |screens| screens.first }

      if s.display != self
        raise Exception.new "Screen does not belong to this Display."
      end

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

      # Shouldn't reach for now
      emit ::Crysterm::Event::Detach, self
    end
  end
end
