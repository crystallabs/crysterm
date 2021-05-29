require "json"
require "event_handler"

require "./ext"
require "./version"
require "./macros"
require "./namespace"
require "./event"
require "./screen"
require "./helpers"
require "./colors"
require "./window"

require "./widget/*"

# Main Crysterm module and namespace.
module Crysterm
  include Namespace

  @@resize_flag : Atomic(UInt8) = Atomic.new 0u8
  @@resize_channel : Channel(Bool) = Channel(Bool).new

  # Amount of time to wait before redrawing the window, after the terminal resize event is received.
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

  # Creates and/or returns main `Screen`
  def self.screen
    Screen.global true
  end

  # Creates and/or returns main `Window`
  def self.window
    Window.global true
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
      _resize
      if @@resize_flag.lazy_get == 2
        break
      else
        @@resize_flag.swap 0
      end
    end
  end

  def self._resize
    # TODO For all `Screen`s, run function to recheck size.
  end

  spawn resize_loop

  at_exit do
    Screen.instances.each &.destroy
  end
end
