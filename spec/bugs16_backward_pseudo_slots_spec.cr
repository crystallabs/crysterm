require "./spec_helper"

include Crysterm

# Regression specs for BUGS16 B16-25: backward/only structural pseudo-classes
# (`:last-child`, `:nth-last-child`, ...) never matched sub-element slot
# subjects. A slot rule like `Box:last-child::scrollbar` lowers to
# `.Box:last-child .Scrollbar`, whose subject exists only in the *full* CSS
# document — where the host's backward pseudo miscounts against the trailing
# `<w-scrollbar>`/`<w-track>` pseudo-nodes (the very miscount the structural
# document fixed for widget subjects), and whose `A > B:last-child .Slot`
# shape the selector engine can't even compile. The cascade now splits such a
# rule at the last top-level combinator: the prefix matches hosts against the
# structural document, the slot compound matches slot nodes against the full
# document, joined by host uid (is-or-descends-from, matching the descendant
# combinator the `::slot` lowering inserts).

private def headless_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

# Runs *block* with the global default (user-agent) stylesheet emptied, then
# restores it, so asserting `fg == nil` isn't foiled by the auto-installed theme.
private def without_default_theme(&)
  saved = Crysterm::CSS.default_stylesheet
  Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
  begin
    yield
  ensure
    Crysterm::CSS.default_stylesheet = saved
  end
end

private def rgb(name)
  Crysterm::Colors.convert(name).to_i32
end

describe "BUGS16 backward structural pseudos on sub-element slot subjects (B16-25)" do
  it "matches A > B:last-child::slot (child-then-descendant shape the engine can't compile)" do
    screen = headless_screen
    parent = Widget::Box.new(scrollbar: true)
    screen.append parent
    c1 = Widget::Box.new(parent: parent, scrollbar: true)
    c2 = Widget::Box.new(parent: parent, scrollbar: true)
    without_default_theme do
      screen.stylesheet = "Box > Box:last-child::scrollbar { color: red; }"
      screen.apply_stylesheet

      c2.styles.normal.scrollbar.fg.should eq rgb("red")
      c1.styles.normal.scrollbar.fg.should be_nil
    end
  end

  it "matches Host:last-child::slot despite the host parent's trailing pseudo-nodes" do
    screen = headless_screen
    # The parent's own scrollbar emits trailing <w-scrollbar>/<w-track> nodes
    # after the real children, which used to steal the last-child slot in the
    # full document (the only place slot subjects were matched).
    parent = Widget::Box.new(scrollbar: true)
    screen.append parent
    c1 = Widget::Box.new(parent: parent, scrollbar: true)
    c2 = Widget::Box.new(parent: parent, scrollbar: true)
    c1.add_css_class "pane"
    c2.add_css_class "pane"
    without_default_theme do
      screen.stylesheet = ".pane:last-child::scrollbar { color: red; }"
      screen.apply_stylesheet

      c2.styles.normal.scrollbar.fg.should eq rgb("red")
      c1.styles.normal.scrollbar.fg.should be_nil
    end
  end

  it "matches :nth-last-child on a slot subject counting only real siblings" do
    screen = headless_screen
    parent = Widget::Box.new(scrollbar: true)
    screen.append parent
    c1 = Widget::Box.new(parent: parent, scrollbar: true)
    c2 = Widget::Box.new(parent: parent, scrollbar: true)
    without_default_theme do
      screen.stylesheet = "Box > Box:nth-last-child(2)::scrollbar { color: red; }"
      screen.apply_stylesheet

      c1.styles.normal.scrollbar.fg.should eq rgb("red")
      c2.styles.normal.scrollbar.fg.should be_nil
    end
  end

  it "reaches slots of widgets nested under the matched host (descendant semantics)" do
    screen = headless_screen
    wrap = Widget::Box.new(scrollbar: true)
    screen.append wrap
    a = Widget::Box.new(parent: wrap, scrollbar: true)
    b = Widget::Box.new(parent: wrap)
    a.add_css_class "sect"
    b.add_css_class "sect"
    inner = Widget::Box.new(parent: b, scrollbar: true)
    without_default_theme do
      # The `::slot` lowering inserts a descendant combinator, so the rule
      # also styles scrollbars nested anywhere under the matched last child.
      screen.stylesheet = ".sect:last-child::scrollbar { color: red; }"
      screen.apply_stylesheet

      inner.styles.normal.scrollbar.fg.should eq rgb("red")
      a.styles.normal.scrollbar.fg.should be_nil
    end
  end

  it "keeps widget-subject backward pseudos and slot-subject rules independent" do
    screen = headless_screen
    parent = Widget::Box.new(scrollbar: true)
    screen.append parent
    c1 = Widget::Box.new(parent: parent, scrollbar: true)
    c2 = Widget::Box.new(parent: parent, scrollbar: true)
    without_default_theme do
      screen.stylesheet = <<-CSS
        Box > Box:last-child { color: blue; }
        Box > Box:last-child::scrollbar { color: red; }
        CSS
      screen.apply_stylesheet

      c2.styles.normal.fg.should eq rgb("blue")
      c2.styles.normal.scrollbar.fg.should eq rgb("red")
      c1.styles.normal.fg.should be_nil
    end
  end
end
