require "./spec_helper"

include Crysterm

# `Action` (src/action.cr, modeled on Qt's `QAction`) represents a command that
# can be invoked from several interfaces and re-run uniformly. It is *not* a
# widget, so it has no example under `examples/widget/`; these assertions are the
# only coverage of its activation/event behavior. Migrated from the former
# `small-tests/action.cr` smoke test, which only `p`-printed.
describe Crysterm::Action do
  describe "#activate" do
    it "emits Triggered by default" do
      a = Action.new
      fired = [] of String
      a.on(Event::Triggered) { fired << "triggered" }
      a.on(Event::Hovered) { fired << "hovered" }

      a.activate

      fired.should eq ["triggered"]
    end

    it "emits the event explicitly passed to it" do
      a = Action.new
      fired = [] of String
      a.on(Event::Triggered) { fired << "triggered" }
      a.on(Event::Hovered) { fired << "hovered" }

      a.activate Event::Triggered
      a.activate Event::Hovered

      fired.should eq ["triggered", "hovered"]
    end

    it "runs every handler registered for the same event, in registration order" do
      a = Action.new
      order = [] of Int32
      a.on(Event::Triggered) { order << 1 }
      a.on(Event::Triggered) { order << 2 }

      a.activate Event::Triggered

      order.should eq [1, 2]
    end

    it "does not fire Triggered handlers when only Hovered is activated" do
      a = Action.new
      triggered = 0
      a.on(Event::Triggered) { triggered += 1 }

      a.activate Event::Hovered

      triggered.should eq 0
    end
  end

  # The `Widgets` convenience namespace must alias the real `Crysterm::Action`
  # (there is no `Widget::Action`). Referencing the alias forces its lazy
  # resolution, guarding against the broken `Action = Widget::Action` mapping.
  it "is reachable via the Widgets convenience namespace" do
    Crysterm::Widgets::Action.should eq Crysterm::Action
  end
end
