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
module Crysterm
  include Namespace

  # NOTE Good idea to provide a default instance, or not?
  # class_property style = Style.new

  TAB_SIZE = 4

  TAG_REGEX = /\{(\/?)([\w\-,;!#]*)\}/
  SGR_REGEX = /\x1b\[[\d;]*m/

  # Amount of time to wait before redrawing the screen, after the terminal resize event is received.
  #
  # The default, and also the value used in Qt, is 0.3 seconds. An alternative setting used in console
  # apps is 0.2 seconds.
  class_property resize_interval : Time::Span = 0.3.seconds
  # class_property resize_interval : Float = 1/29

  Signal::WINCH.trap do
    schedule_resize
  end

  Signal::TERM.trap do
    exit
  end

  Signal::QUIT.trap do
    exit
  end

  Signal::KILL.trap do
    exit
  end

  # Creates and/or returns main `Display`
  def self.display
    Display.global true
  end

  # Creates and/or returns main `Screen`
  def self.screen
    Screen.global true
  end

  private def self.schedule_resize
    @@resize_fiber.try &.timeout(@@resize_interval)
  end

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

  @@resize_fiber = Fiber.new "resize_loop" { resize_loop }

  at_exit do
    Display.instances.each &.destroy
  end
end
