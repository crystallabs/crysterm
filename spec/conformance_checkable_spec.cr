require "./spec_helper"

include Crysterm

# FORMAL-WIDGETS Part B / B8 — shared behavioral conformance for the checkable
# family. Two matrices:
#
#   * `it_behaves_like_a_checkable` — a single toggling control (`CheckBox`,
#     `RadioButton`, a checkable `Button`, a checkable `ToolButton`): `check`/
#     `uncheck` are idempotent and emit exactly one `Event::Check`/`UnCheck` on a
#     real transition; a `toggle` from unchecked emits exactly once and ends
#     checked. (All four subclass `AbstractButton`, so one adapter cast covers
#     them.)
#   * `it_behaves_like_an_exclusive_group` — the "exactly one selected" invariant
#     encoded three ways in the tree (B5.7): `ButtonGroup` (explicit group) and a
#     `RadioSet` of `RadioButton`s (tree-scoped) must keep exactly one member set.

private def mem_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

private record CheckableCase,
  name : String,
  build : Proc(Crysterm::Window, Crysterm::Widget::AbstractButton)

private def it_behaves_like_a_checkable(c : CheckableCase)
  describe c.name do
    it "checks once and is idempotent" do
      s = mem_screen
      b = c.build.call s
      checks = 0
      b.on(Crysterm::Event::Check) { checks += 1 }
      b.check
      b.checked?.should be_true
      checks.should eq 1
      b.check # already checked — no re-emit
      checks.should eq 1
    end

    it "unchecks once and is idempotent" do
      s = mem_screen
      b = c.build.call s
      b.check
      unchecks = 0
      b.on(Crysterm::Event::UnCheck) { unchecks += 1 }
      b.uncheck
      b.checked?.should be_false
      unchecks.should eq 1
      b.uncheck # already unchecked — no re-emit
      unchecks.should eq 1
    end

    it "emits exactly one event on a toggle from unchecked and ends checked" do
      s = mem_screen
      b = c.build.call s
      events = 0
      b.on(Crysterm::Event::Check) { events += 1 }
      b.on(Crysterm::Event::UnCheck) { events += 1 }
      b.toggle
      b.checked?.should be_true
      events.should eq 1
    end
  end
end

private record GroupCase,
  name : String,
  setup : Proc(Crysterm::Window, Array(Crysterm::Widget::AbstractButton))

private def it_behaves_like_an_exclusive_group(c : GroupCase)
  describe c.name do
    it "keeps exactly one member selected" do
      s = mem_screen
      members = c.setup.call s
      members[0].check
      members[1].check
      members.count(&.checked?).should eq 1
      members[1].checked?.should be_true
      members[0].checked?.should be_false
    end
  end
end

describe "Checkable conformance (B8)" do
  it_behaves_like_a_checkable CheckableCase.new(
    name: "CheckBox",
    build: ->(s : Crysterm::Window) { Crysterm::Widget::CheckBox.new(parent: s).as(Crysterm::Widget::AbstractButton) },
  )

  it_behaves_like_a_checkable CheckableCase.new(
    name: "RadioButton",
    build: ->(s : Crysterm::Window) { Crysterm::Widget::RadioButton.new(parent: s).as(Crysterm::Widget::AbstractButton) },
  )

  it_behaves_like_a_checkable CheckableCase.new(
    name: "Button (checkable)",
    build: ->(s : Crysterm::Window) { Crysterm::Widget::Button.new(parent: s, checkable: true).as(Crysterm::Widget::AbstractButton) },
  )

  it_behaves_like_a_checkable CheckableCase.new(
    name: "ToolButton (checkable)",
    build: ->(s : Crysterm::Window) { Crysterm::Widget::ToolButton.new(parent: s, checkable: true, content: "T").as(Crysterm::Widget::AbstractButton) },
  )

  it_behaves_like_an_exclusive_group GroupCase.new(
    name: "ButtonGroup",
    setup: ->(s : Crysterm::Window) {
      g = Crysterm::ButtonGroup.new exclusive: true
      members = Array(Crysterm::Widget::AbstractButton).new
      3.times do
        b = Crysterm::Widget::Button.new parent: s
        g.add b
        members << b
      end
      members
    },
  )

  it_behaves_like_an_exclusive_group GroupCase.new(
    name: "RadioSet",
    setup: ->(s : Crysterm::Window) {
      rs = Crysterm::Widget::RadioSet.new parent: s
      members = Array(Crysterm::Widget::AbstractButton).new
      3.times do
        r = Crysterm::Widget::RadioButton.new parent: rs
        members << r
      end
      members
    },
  )
end
