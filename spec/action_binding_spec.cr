require "./spec_helper"

include Crysterm

# `Action#bind_checked` / `#bind_enabled`: a menu entry's state kept on
# the state it stands for — a reactive property (two-way for a Bool,
# derived for anything else) or a widget's event — instead of being
# re-synced by hand.

describe "Action#bind_checked" do
  it "keeps the check on a Bool property, both ways" do
    follow = Reactive::Property.new false
    action = Action.new "Follow", checkable: true
    action.bind_checked follow
    action.checked?.should be_false
    follow.value = true
    action.checked?.should be_true
    action.trigger
    action.checked?.should be_false
    follow.value.should be_false
    action.trigger
    follow.value.should be_true
  end

  it "derives the check from a property, as a radio group over an enum" do
    mode = Reactive::Property.new 0
    group = ActionGroup.new
    actions = (0..2).map do |i|
      a = Action.new "Mode #{i}", checkable: true
      a.bind_checked(mode) { mode.value == i }
      a.on(Event::Triggered) { mode.value = i }
      group.add_action a
      a
    end
    actions.map(&.checked?).should eq [true, false, false]
    mode.value = 2
    actions.map(&.checked?).should eq [false, false, true]
    actions[1].trigger
    mode.value.should eq 1
    actions.map(&.checked?).should eq [false, true, false]
  end

  it "follows a widget's state through its event" do
    s = headless_screen(40, 8)
    e = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 40, height: 4
    action = Action.new "Overwrite", checkable: true
    action.bind_checked(e, Event::OverwriteModeChanged) { e.overwrite_mode? }
    action.checked?.should be_false
    e.overwrite_mode = true
    action.checked?.should be_true
    e.overwrite_mode = false
    action.checked?.should be_false
    s.destroy
  end
end

describe "Action#bind_enabled" do
  it "derives enabled from a property" do
    count = Reactive::Property.new 0
    action = Action.new "Undo"
    action.bind_enabled(count) { count.value > 0 }
    action.enabled?.should be_false
    count.value = 3
    action.enabled?.should be_true
    count.value = 0
    action.enabled?.should be_false
  end

  it "follows a widget's state through its event" do
    s = headless_screen(40, 8)
    w = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 2
    w.hide
    action = Action.new "Close pane"
    action.bind_enabled(w, Event::Show) { w.visible? }
    action.enabled?.should be_false
    w.show
    action.enabled?.should be_true
    s.destroy
  end
end
