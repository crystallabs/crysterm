require "json"

require "event_handler"

require "./version"
require "./macros"
require "./namespace"
require "./config"
require "./unicode"
require "./event"
require "./helpers"
require "./colors"
require "./timer"
require "./docking"
require "pnggif"

require "./mixin/*"

require "./action"

require "./cursor"

require "./screen"
require "./terminal/launchers"
require "./terminal/handshake"
require "./screen_connection"

require "./widget"
require "./widget/**"
require "./widgets"

# Main Crysterm module and namespace.
#
# If your code is in its own namespace, you can shorten `Crysterm` to an
# alias of your choosing, e.g. "C":
#
# ```
# require "../src/crysterm"
# alias C = Crysterm
#
# s = C::Screen.new
# t = C::Widget::Text.new content: "Hello, World!", style: C::Style.new(bg: "blue", fg: "yellow", border: true), left: "center", top: "center", parent: s
#
# s.append t
# s.on(C::Event::KeyPress) { exit }
#
# s.exec
# ```
module Crysterm
  class GlobalEventsClass
    include EventHandler
  end

  GlobalEvents = GlobalEventsClass.new

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
  Signal::WINCH.trap do
    # XXX IIRC, urwid has an additional method of tracking resizes. Check it out and add
    # additional support here if necessary.
    GlobalEvents.emit Event::Resize
  end

  at_exit do
    Screen.instances.each &.destroy
  end
end

# If this process was launched as an in-window helper by `Screen.open` (env var
# set on the spawned emulator), run the helper loop and exit here — before any
# user code runs. A plain no-op in every normal run. Placed at the very bottom so
# the whole library is loaded by the time it executes.
Crysterm::Terminal.run_helper_if_requested
