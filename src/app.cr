require "term-screen"
require "log"

require "tput"
require "term_colors"
require "crystallabs-helpers"

require "./app/*"

require "./version"
require "./macros"
require "./colors"
require "./helpers"

require "./widget/node"
require "./widget/*"

module Crysterm
  # Main Crysterm class. All applications begin by instantiating or subclassing this class.
  class App
    include EventHandler # Event model

    include Metadata # Simple metadata about the app

    include Instance # Things related to running app instances

    include Tput # Terminal I/O

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
