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
require "./screen"

require "./widget/*"
require "./widgets"

# Main Crysterm module and namespace.
module Crysterm
  include Namespace

  # NOTE Good idea to provide a default instance, or not?
  # class_property style = Style.new

  TAB_SIZE = 4

  # :nodoc:
  @@resize_flag : Atomic(UInt8) = Atomic.new 0u8

  # :nodoc:
  @@resize_channel : Channel(Bool) = Channel(Bool).new

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

  def self.schedule_resize
    _old, succeeded = @@resize_flag.compare_and_set 0, 1
    if succeeded
      @@resize_channel.send true
    end
  end

  def self.resize_loop
    loop do
      if @@resize_channel.receive
        sleep @@resize_interval
      end
      ::Crysterm::Display.instances.each do |display|
        display.tput.reset_screen_size
        display.emit ::Crysterm::Event::Resize
      end
      if @@resize_flag.lazy_get == 2
        break
      else
        @@resize_flag.swap 0
      end
    end
  end

  spawn resize_loop

  at_exit do
    Display.instances.each &.destroy
  end
end
