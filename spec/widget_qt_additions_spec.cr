require "./spec_helper"

include Crysterm

# Behavioral specs for the Qt-inspired additions: `ButtonGroup` (logical
# grouping / exclusivity), `ToolButton` (default action), `DialogButtonBox`
# (standard buttons + accept/reject roles), `ColorDialog`, and `Completer`
# (autocompletion filtering).

private def add_mem_screen
  Crysterm::Screen.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24)
end

describe Crysterm::ButtonGroup do
  it "enforces exclusivity: checking one member unchecks the others" do
    s = add_mem_screen
    a = Crysterm::Widget::CheckBox.new parent: s
    b = Crysterm::Widget::CheckBox.new parent: s
    c = Crysterm::Widget::CheckBox.new parent: s

    g = Crysterm::ButtonGroup.new
    g.add a, 1
    g.add b, 2
    g.add c, 3

    a.check
    a.checked?.should be_true
    b.check
    a.checked?.should be_false
    b.checked?.should be_true
    g.checked_button.should eq b
    g.checked_id.should eq 2
  end

  it "allows multiple checked when non-exclusive" do
    s = add_mem_screen
    a = Crysterm::Widget::CheckBox.new parent: s
    b = Crysterm::Widget::CheckBox.new parent: s

    g = Crysterm::ButtonGroup.new exclusive: false
    g.add a
    g.add b
    a.check
    b.check
    a.checked?.should be_true
    b.checked?.should be_true
  end

  it "emits ButtonClick carrying the checked button" do
    s = add_mem_screen
    a = Crysterm::Widget::CheckBox.new parent: s
    g = Crysterm::ButtonGroup.new
    g.add a, 7
    clicked = nil
    g.on(Crysterm::Event::ButtonClick) { |e| clicked = e.button }
    a.check
    clicked.should eq a
  end

  it "makes a plain Button checkable on add and maps ids" do
    s = add_mem_screen
    btn = Crysterm::Widget::Button.new parent: s
    g = Crysterm::ButtonGroup.new
    g.add btn, 42
    btn.checkable?.should be_true
    g.button(42).should eq btn
    g.id(btn).should eq 42
  end
end

describe Crysterm::Widget::ToolButton do
  it "mirrors the default action's text and triggers it on press" do
    s = add_mem_screen
    act = Crysterm::Action.new "Save"
    triggered = false
    act.on(Crysterm::Event::Triggered) { triggered = true }

    tb = Crysterm::Widget::ToolButton.new parent: s, action: act
    tb.content.should eq "Save"
    tb.press
    triggered.should be_true
  end

  it "does not trigger a disabled action" do
    s = add_mem_screen
    act = Crysterm::Action.new "Nope"
    act.enabled = false
    triggered = false
    act.on(Crysterm::Event::Triggered) { triggered = true }

    tb = Crysterm::Widget::ToolButton.new parent: s, action: act
    tb.press
    triggered.should be_false
  end
end

describe Crysterm::Widget::DialogButtonBox do
  it "creates the requested standard buttons with correct labels" do
    s = add_mem_screen
    bb = Crysterm::Widget::DialogButtonBox.new(
      parent: s,
      buttons: Crysterm::Widget::DialogButtonBox::StandardButton::Ok |
               Crysterm::Widget::DialogButtonBox::StandardButton::Cancel,
    )
    bb.buttons.size.should eq 2
    bb.button(Crysterm::Widget::DialogButtonBox::StandardButton::Ok).should_not be_nil
    bb.button(Crysterm::Widget::DialogButtonBox::StandardButton::Cancel).should_not be_nil
    bb.button(Crysterm::Widget::DialogButtonBox::StandardButton::Save).should be_nil
  end

  it "emits Accepted for accept-role and Rejected for reject-role buttons" do
    s = add_mem_screen
    bb = Crysterm::Widget::DialogButtonBox.new(
      parent: s,
      buttons: Crysterm::Widget::DialogButtonBox::StandardButton::Ok |
               Crysterm::Widget::DialogButtonBox::StandardButton::Cancel,
    )
    accepted = rejected = false
    bb.on(Crysterm::Event::Accepted) { accepted = true }
    bb.on(Crysterm::Event::Rejected) { rejected = true }

    bb.button(Crysterm::Widget::DialogButtonBox::StandardButton::Ok).not_nil!.press
    accepted.should be_true
    rejected.should be_false

    bb.button(Crysterm::Widget::DialogButtonBox::StandardButton::Cancel).not_nil!.press
    rejected.should be_true
  end

  it "adds custom buttons via add_button" do
    s = add_mem_screen
    bb = Crysterm::Widget::DialogButtonBox.new parent: s
    b = bb.add_button "Custom", Crysterm::Widget::DialogButtonBox::Role::Accept
    bb.buttons.includes?(b).should be_true
  end
end

describe Crysterm::Widget::ColorDialog do
  it "converts hex colors to an HSV state and back to hex (round-trips)" do
    s = add_mem_screen
    cd = Crysterm::Widget::ColorDialog.new parent: s, width: 50, height: 18
    cd.set_color "#ff0000"
    cd.current_color.should eq "#ff0000"
    cd.set_color "#00ff00"
    cd.current_color.should eq "#00ff00"
    cd.set_color "#336699"
    cd.current_color.should eq "#336699"
  end

  it "emits Action+Accepted on accept and Rejected on cancel" do
    s = add_mem_screen
    cd = Crysterm::Widget::ColorDialog.new parent: s, width: 50, height: 18
    cd.set_color "#0000ff"
    chosen = nil
    accepted = rejected = false
    cd.on(Crysterm::Event::Action) { |e| chosen = e.value }
    cd.on(Crysterm::Event::Accepted) { accepted = true }
    cd.on(Crysterm::Event::Rejected) { rejected = true }

    cd.accept
    chosen.should eq "#0000ff"
    accepted.should be_true

    cd.cancel
    rejected.should be_true
  end
end

describe Crysterm::Completer do
  it "filters the model by case-insensitive prefix" do
    c = Crysterm::Completer.new %w[apple apricot banana blueberry]
    c.completions("ap").should eq %w[apple apricot]
    c.completions("AP").should eq %w[apple apricot] # case-insensitive by default
    c.completions("").should be_empty
    c.completions("zzz").should be_empty
  end

  it "honors case sensitivity and substring mode" do
    c = Crysterm::Completer.new %w[Apple apricot BANANA]
    c.case_sensitive = true
    c.completions("ap").should eq %w[apricot]

    c.case_sensitive = false
    c.mode = Crysterm::Completer::Mode::SubstringMatch
    c.completions("an").should eq %w[BANANA]
  end

  it "attaches to a text box without raising" do
    s = add_mem_screen
    box = Crysterm::Widget::LineEdit.new parent: s, width: 20, height: 1
    c = Crysterm::Completer.new %w[apple apricot]
    c.attach box
    c.open?.should be_false
    c.detach
  end
end
