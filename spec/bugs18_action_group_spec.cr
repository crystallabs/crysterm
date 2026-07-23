require "./spec_helper"

include Crysterm

# B18-91 / B18-99: `ActionGroup` exclusivity edge cases.
#
# B18-91: re-triggering the already-checked member of an *exclusive* group used
# to unconditionally flip it off (`Action#activate`'s unconditional
# `self.checked = !checked?`), and `ActionGroup`'s Triggered/Toggled relays
# could never recover from that — `enforce_exclusivity` early-returns unless
# the just-activated member is still checked, and the Toggled relay only acts
# `if e.checked`. Net effect: re-selecting the current radio option cleared the
# whole group (`checked_action` went to `nil`). Qt's `QAction::activate`
# suppresses exactly this off-toggle for an exclusive group's checked member;
# so must Crysterm's.
#
# B18-99: `ActionGroup#exclusive=` used to be a plain property, so turning
# exclusivity on *after* members were added (unlike passing `exclusive: true`
# at construction, or via `#add_action`, both of which force members
# checkable) left every member non-checkable — activation could then never
# check anything, and `checked_action` stayed `nil` forever.
describe Crysterm::ActionGroup do
  describe "re-triggering the checked member (B18-91)" do
    it "keeps the checked member checked in an exclusive group (Qt's off-toggle suppression)" do
      g = Crysterm::ActionGroup.new exclusive: true
      a = Crysterm::Action.new "Icons"
      b = Crysterm::Action.new "List"
      c = Crysterm::Action.new "Details"
      g << a << b << c

      a.trigger
      g.checked_action.should eq a

      # Re-triggering the already-checked member must NOT clear the group.
      a.trigger
      a.checked?.should be_true
      g.checked_action.should eq a
      b.checked?.should be_false
      c.checked?.should be_false
    end

    it "still emits Triggered on re-trigger, carrying the (unchanged) checked state" do
      g = Crysterm::ActionGroup.new
      a = Crysterm::Action.new "Icons"
      g << a
      payloads = [] of Bool
      g.on(Crysterm::Event::Triggered) { |e| payloads << e.checked }

      a.trigger
      a.trigger
      payloads.should eq [true, true]
    end

    it "still unchecks on re-trigger in a non-exclusive group" do
      g = Crysterm::ActionGroup.new exclusive: false
      a = Crysterm::Action.new "Bold", checkable: true
      g << a

      a.trigger
      a.checked?.should be_true
      a.trigger
      a.checked?.should be_false
    end

    it "still unchecks a group-less checkable action on re-trigger" do
      a = Crysterm::Action.new "Bold", checkable: true
      a.trigger
      a.checked?.should be_true
      a.trigger
      a.checked?.should be_false
    end

    it "#toggle and #checked= still uncheck an exclusive group's checked member (only #activate is suppressed)" do
      g = Crysterm::ActionGroup.new
      a = Crysterm::Action.new "Icons"
      g << a
      a.trigger
      a.checked?.should be_true

      a.toggle
      a.checked?.should be_false

      a.checked = true
      a.checked?.should be_true
      a.checked = false
      a.checked?.should be_false
    end

    it "moving an action from one exclusive group to another drops it from the first (single-group backref)" do
      g1 = Crysterm::ActionGroup.new
      g2 = Crysterm::ActionGroup.new
      a = Crysterm::Action.new "Shared"
      b = Crysterm::Action.new "OnlyG1"
      g1 << a << b
      a.trigger
      g1.checked_action.should eq a

      g2 << a
      # `a` now belongs to g2 only; re-triggering it must be judged against g2's
      # exclusivity, not stale g1 state, and g1 must no longer relay it.
      a.trigger
      a.checked?.should be_true
      g2.checked_action.should eq a

      b.trigger
      g1.checked_action.should eq b
    end
  end

  describe "#exclusive= after members were added (B18-99)" do
    it "forces existing members checkable, so activation can check one" do
      g = Crysterm::ActionGroup.new exclusive: false
      a = Crysterm::Action.new "Icons"
      b = Crysterm::Action.new "List"
      c = Crysterm::Action.new "Details"
      g << a << b << c
      a.checkable?.should be_false

      g.exclusive = true
      a.checkable?.should be_true
      b.checkable?.should be_true
      c.checkable?.should be_true

      b.trigger
      g.checked_action.should eq b
    end

    it "reconciles down to one checked member when several were already checked" do
      g = Crysterm::ActionGroup.new exclusive: false
      a = Crysterm::Action.new "Icons", checkable: true, checked: true
      b = Crysterm::Action.new "List", checkable: true, checked: true
      g << a << b

      g.exclusive = true
      g.checked_action.should eq a
      b.checked?.should be_false
    end

    it "is a no-op when re-set to the same value (no spurious churn)" do
      g = Crysterm::ActionGroup.new exclusive: true
      a = Crysterm::Action.new "Icons"
      g << a
      a.checkable = false

      g.exclusive = true
      a.checkable?.should be_false
    end

    it "does not force checkable when turned off" do
      g = Crysterm::ActionGroup.new exclusive: true
      a = Crysterm::Action.new "Icons"
      g << a
      a.checkable?.should be_true

      g.exclusive = false
      a.checkable?.should be_true # untouched, just no longer forced going forward

      b = Crysterm::Action.new "List"
      g << b
      b.checkable?.should be_false
    end
  end
end
