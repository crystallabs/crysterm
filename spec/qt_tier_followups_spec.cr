require "./spec_helper"

include Crysterm

# Behavioral coverage for the Qt-informed follow-ups (E22 char propagation,
# F28 deselectable radio).
describe "E22 — always_propagated_chars" do
  it "accepts ordinary character keys via Window.new and holds them" do
    win = Crysterm::Window.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      always_propagated_chars: ['q', 'x'])
    win.always_propagated_chars.should eq ['q', 'x']
  end

  it "defaults to an empty list, leaving always_propagated_keys untouched" do
    win = headless_screen(20, 6, default_quit_keys: true)
    win.always_propagated_chars.empty?.should be_true
    win.always_propagated_keys.empty?.should be_true
  end
end

describe "F28 — RadioButton#deselectable" do
  it "a plain radio stays checked when toggled (Qt default: one stays selected)" do
    win = headless_screen(20, 6, default_quit_keys: true)
    rb = Crysterm::Widget::RadioButton.new(checked: true, parent: win)
    rb.deselectable?.should be_false
    rb.toggle
    rb.checked?.should be_true
  end

  it "a deselectable radio unchecks when toggled, so the set can go empty" do
    win = headless_screen(20, 6, default_quit_keys: true)
    rb = Crysterm::Widget::RadioButton.new(checked: true, deselectable: true, parent: win)
    rb.checked?.should be_true
    rb.toggle
    rb.checked?.should be_false
    rb.toggle # and back on
    rb.checked?.should be_true
  end
end

describe "Styles#each / #each_entry" do
  it "yields only the set states (always normal), with WidgetState in each_entry" do
    styles = Crysterm::Styles.new(Crysterm::Style.new)

    seen = [] of Crysterm::Style
    styles.each { |s| seen << s }
    seen.size.should eq 1 # normal only

    entries = [] of Crysterm::WidgetState
    styles.each_entry { |st, _| entries << st }
    entries.should eq [Crysterm::WidgetState::Normal]

    styles.focused = Crysterm::Style.new
    states = [] of Crysterm::WidgetState
    styles.each_entry { |st, _| states << st }
    states.should eq [Crysterm::WidgetState::Normal, Crysterm::WidgetState::Focused]
  end
end
