require "./spec_helper"

include Crysterm

# Reparenting a widget from one container to another *on the same screen* must
# not churn the screen-level `Event::Attach`/`Event::Detach`: the widget never
# leaves the screen, so those transition events are spurious. Real handlers key
# off them — e.g. a `Media`/überzug overlay clears its still-visible image on
# `Detach`, and a carousel/`Table` re-runs setup on `Attach` — so firing them on
# a pure tree-position change is a visible defect (`Widget#insert`/`#remove`,
# src/widget_children.cr). A genuine *cross-screen* move must still fire both.

private def headless_screen
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 20, height: 10)
end

describe "Widget reparenting within the same screen" do
  it "does not emit Attach/Detach when a child moves between containers on one screen" do
    s = headless_screen
    a = Widget::Box.new parent: s, width: "100%", height: "100%"
    b = Widget::Box.new parent: s, width: "100%", height: "100%"
    child = Widget::Box.new width: 4, height: 2
    a.append child

    transitions = [] of String
    child.on(Event::Attach) { transitions << "attach" }
    child.on(Event::Detach) { transitions << "detach" }

    b.append child # same-screen move

    # The widget moved, and still derives the same screen...
    child.parent.should eq b
    child.window?.should eq s
    # ...but no screen-transition events fired (it never left the screen).
    transitions.should be_empty
  end

  it "still emits the Reparent sequence on a same-screen move" do
    s = headless_screen
    a = Widget::Box.new parent: s, width: "100%", height: "100%"
    b = Widget::Box.new parent: s, width: "100%", height: "100%"
    child = Widget::Box.new width: 4, height: 2

    seen = [] of Widget?
    child.on(Event::Reparent) { |e| seen << e.widget }

    a.append child # adopt by a
    b.append child # detach from a (nil), then adopt by b

    # Suppressing the screen Attach/Detach must NOT swallow the widget-tree
    # Reparent events (documented in reparent_spec).
    seen.should eq [a, nil, b]
  end

  it "still emits Attach/Detach for a genuine cross-screen move" do
    s1 = headless_screen
    s2 = headless_screen
    a = Widget::Box.new parent: s1, width: "100%", height: "100%"
    b = Widget::Box.new parent: s2, width: "100%", height: "100%"
    child = Widget::Box.new width: 4, height: 2
    a.append child

    transitions = [] of String
    child.on(Event::Attach) { transitions << "attach" }
    child.on(Event::Detach) { transitions << "detach" }

    b.append child # move s1 -> s2

    child.window?.should eq s2
    transitions.should eq ["detach", "attach"]
  end
end
