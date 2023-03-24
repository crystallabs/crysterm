require "json"

require "event_handler"

require "./ext"
require "./version"
require "./macros"
require "./namespace"
require "./event"
require "./helpers"
require "./colors"

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
# t = C::Text.new content: "Hello, World!"
#
# alias TUI = Crysterm
# t = TUI::Text.new content: "Hello, World!"
# ...
# ```
#
# Or if you want to import all the widgets into your current namespace, do:
#
# ```
# include Crysterm::Widgets
# t = Text.new content: "Hello, World!"
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
