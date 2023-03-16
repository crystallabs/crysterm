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

require "./mixin/*"

require "./action"

require "./screen"

require "./widget"
require "./widget/**"
require "./widgets"

# Main Crysterm module and namespace.
#
# If your code is in its own namespace, you can shorten `Crysterm` to an
# alias of your choosing, e.g.:
#
# ```
# alias C = Crysterm
# alias GUI = Crysterm
# ...
# ```
module Crysterm
  # Amount of time to wait before redrawing the screen, after the last successive terminal resize event is received.
  #
  # The value used in Qt is 0.3 seconds.
  # The value commonly used in console apps is 0.2 seconds.
  # Yet another choice could be the frame rate, i.e. 1/29 seconds.
  class_property resize_interval : Time::Span = 0.2.seconds

  # TODO Should all of these run a proper exit sequence, instead of just exit ad-hoc?
  # (Currently we just call `exit` and count on `at_exit` handlers being invoked, but they
  # are unordered)
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

  # The rest of code here is related to handling resize events

  # Listens for WINCH signal
  # XXX IIRC, urwid has an additional method of tracking resizes. Check it out and add
  # support if necessary.
  Signal::WINCH.trap do
    schedule_resize
  end

  # Schedules `@@resize_fiber` to run at now + `@@resize_interval`. Repeated invocations
  # (before the interval has elapsed) have a (desirable) effect of delaying/re-starting the
  # timer til the fiber is to be scheduled.
  private def self.schedule_resize
    @@resize_fiber.try &.timeout(@@resize_interval)
  end

  # :nodoc:
  @@resize_fiber = Fiber.new "resize_loop" { resize_loop }

  # :nodoc:
  # TODO Will this be affected when we move all GUI actions happening in a single thread?
  def self.resize_loop
    loop do
      resize
      sleep
    end
  end

  # Re-reads current size of all `Display`s and triggers redraw of all `Screen`s.
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
end
