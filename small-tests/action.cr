require "../src/crysterm"

module Crysterm
  a = Action.new { p "Action has triggered (1st handler)" }

  a.on(Action::Event::Triggered) do
    p "Action has triggered (2nd handler)"
  end

  a.activate
end
