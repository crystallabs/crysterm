require "json"
require "event_handler"

require "./ext"
require "./version"
require "./macros"
require "./namespace"
require "./event"
require "./display"
require "./helpers"
require "./colors"

require "./object"

require "./action"

require "./screen"

require "./widget"
require "./widget/**"
require "./widgets"

# Main Crysterm module and namespace.
#
# If your code is in its own namespace, you could shorten `Crysterm` with an
# alias of your choosing, such as:
#
# ```
# alias C = Crysterm
# alias GUI = Crysterm
# ```
module Crysterm
  include Namespace

  # NOTE Good idea to provide a default instance, or not?
  # class_property style = Style.new

  # Default TAB size in number of characters. This value gets used as a default for `Style#tab_size`.
  TAB_SIZE = 4

  # Convenience regex for matching Crysterm tags and their content (i.e. '{bold}This text is bold{/bold}').
  TAG_REGEX = /\{(\/?)([\w\-,;!#]*)\}/

  # Convenience regex for matching SGR sequences.
  SGR_REGEX = /\e\[[\d;]*m/

  # :ditto:
  SGR_REGEX_AT_BEGINNING = /^#{SGR_REGEX}/

  # Amount of time to wait before redrawing the screen, after the last successive terminal resize event is received.
  #
  # The value used in Qt is 0.3 seconds.
  # The value commonly used in console apps is 0.2 seconds.
  # Yet another choice could be the frame rate, i.e. 1/29 seconds.
  class_property resize_interval : Time::Span = 0.2.seconds

  # :nodoc:
  @@resize_fiber = Fiber.new "resize_loop" { resize_loop }

  # TODO Should all of these run a proper exit sequence, instead of just exit ad-hoc?
  Signal::TERM.trap do
    exit
  end
  Signal::QUIT.trap do
    exit
  end
  Signal::KILL.trap do
    exit
  end
  at_exit do
    Display.instances.each &.destroy
  end

  Signal::WINCH.trap do
    schedule_resize
  end

  private def self.schedule_resize
    @@resize_fiber.try &.timeout(@@resize_interval)
  end

  # Re-reads current size of all `Display`s and redraws all `Screen`s.
  #
  # NOTE There is currently no detection for which `Display` the resize has
  # happened on, so a resize in any one managed display causes an update and
  # redraw of all displays.
  def self.resize
    ::Crysterm::Display.instances.each do |display|
      display.tput.reset_screen_size
      display.emit ::Crysterm::Event::Resize
    end
  end

  # :nodoc:
  def self.resize_loop
    loop do
      resize
      sleep
    end
  end

  # Creates and/or returns the main/global/default `Display`.
  def self.display
    Display.global true
  end

  # Creates and/or returns the main/global/default `Screen`.
  def self.screen
    Screen.global true
  end
end
