require "../src/crysterm"

module Crysterm
  a = Action.new

  a.on(Event::Hovered) do
    p "Action has hovered"
  end

  a.on(Event::Triggered) do
    p "Action has triggered (1st handler)"
  end

  a.on(Event::Triggered) do
    p "Action has triggered (2nd handler)"
  end

  # Don't do it for now since Menu is a widget, and it implicitly creates
  # a Screen, so it switches terminal to alt buffer, hiding
  # printed messages.
  # m = Widget::Menu.new "Menu1"
  # m << a

  a.activate
  a.activate(Event::Triggered)
  a.activate(Event::Hovered)

  # Not available in Crystal API (to always use #activate instead)
  # a.trigger
  # a.hover
end
