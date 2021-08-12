require "../src/crysterm"

module Crysterm
  a = Action.new { p "Action has triggered (1st handler)" }

  a.on(Action::Event::Triggered) do
    p "Action has triggered (2nd handler)"
  end

  # Don't do it for now since Menu is a widget, and it implicitly creates
  # a Display and Screen, so it switches terminal to alt buffer, hiding
  # printed messages.
  # m = Widget::Menu.new "Menu1"
  # m << a

  a.activate
  # a.trigger
  # a.hover

end
