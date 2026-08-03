require "./spec_helper"

include Crysterm

# `Widget::Chat::FleetView` (the multi-agent dashboard): per-task detached
# transcript contexts in a `StackedWidget`, the roster→page wiring, the
# open/return focus flow, context teardown on task removal, and the header's
# running/active/peak readout — all bound to the same `Chat::TaskRegistry`
# the inline `TaskStrip` uses.
#
# Widget-typed expectations deliberately use `x.same?(y).should be_true` /
# `x.nil?.should be_true` instead of `should be` / `should be_nil`: the
# matcher forms instantiate `inspect` for the failure message, which on a
# widget's object graph makes the compiler's semantic phase blow up
# (multi-GB, effectively never finishes). Plain-data operands (Task, ints,
# strings) are unaffected.

private def fleet_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 100,
    height: 30,
    default_quit_keys: false,
    optimization: Crysterm::OptimizationFlag::DamageTracking)
end

# The window stays reachable through the fleet's parent chain, so returning
# just the fleet keeps it alive for the example's duration.
private def new_fleet(registry = Crysterm::Chat::TaskRegistry.new)
  fleet = Crysterm::Widget::Chat::FleetView.new registry,
    parent: fleet_screen, top: 0, left: 0, width: 100, height: 30,
    animate: false
  # Lay out once so the roster's `@lpos` is set and `current_index=` reaches
  # its `ItemSelected` emit (the item-view family gates it on layout).
  fleet.window?.try &.repaint
  fleet
end

private def agent(reg, label)
  reg.add label, Crysterm::Chat::Task::Kind::Agent
end

describe Crysterm::Widget::Chat::FleetView do
  it "starts on the placeholder with an empty registry" do
    fleet = new_fleet
    fleet.pages.current_widget.same?(fleet.placeholder).should be_true
    fleet.pages.count.should eq 1
    fleet.current_transcript.nil?.should be_true
    fleet.current_task.should be_nil
    fleet.header.content.should contain "Fleet"
    fleet.header.content.should contain "0 agents"
    fleet.header.content.should contain "0 running"
    fleet.header.content.should contain "peak 0"
  end

  it "mirrors the shared registry in its roster (one model, many views)" do
    reg = Crysterm::Chat::TaskRegistry.new
    reg.add "Bash(npm test)"
    fleet = new_fleet reg
    b = agent reg, "explorer"

    fleet.roster.item_texts.size.should eq 2
    fleet.roster.item_texts[0].should contain "Bash(npm test)"
    fleet.roster.item_texts[1].should contain "explorer"

    reg.transition b, Crysterm::Chat::Task::State::Running
    fleet.roster.item_texts[1].should contain "running…"
  end

  it "raises the selected task's transcript page, created lazily" do
    reg = Crysterm::Chat::TaskRegistry.new
    a = agent reg, "alpha"
    b = agent reg, "beta"
    fleet = new_fleet reg

    # Construction syncs the page to the roster's selection (row 0), so
    # only alpha's context exists yet: placeholder + one page.
    fleet.pages.count.should eq 2
    fleet.context?(a).nil?.should be_false
    fleet.context?(b).nil?.should be_true
    fleet.current_task.should be a

    fleet.roster.current_index = 1
    fleet.pages.count.should eq 3
    fleet.pages.current_widget.same?(fleet.context?(b)).should be_true
    fleet.current_task.should be b
  end

  it "keeps a context collecting appends while its page is hidden" do
    reg = Crysterm::Chat::TaskRegistry.new
    a = agent reg, "alpha"
    b = agent reg, "beta"
    fleet = new_fleet reg

    tr = fleet.transcript_for a
    tr.append Crysterm::Widget::Chat::Transcript::Kind::Prose, "hello from alpha"

    fleet.roster.current_index = 1
    fleet.current_task.should be b
    # Hidden context still receives output (the backend feeds it directly).
    fleet.transcript_for(a).append \
      Crysterm::Widget::Chat::Transcript::Kind::Prose, "still working"

    fleet.roster.current_index = 0
    fleet.current_transcript.same?(tr).should be_true
    tr.entries.size.should eq 2
    tr.entries[1].text.should eq "still working"
  end

  it "Enter on the roster opens the task: page raised, transcript focused" do
    reg = Crysterm::Chat::TaskRegistry.new
    agent reg, "alpha"
    b = agent reg, "beta"
    fleet = new_fleet reg

    fleet.roster.current_index = 1
    e = kp key: ::Tput::Key::Enter
    fleet.roster.on_keypress e
    e.accepted?.should be_true
    fleet.pages.current_widget.same?(fleet.context?(b)).should be_true
    fleet.context?(b).not_nil!.focused?.should be_true
  end

  it "open selects the row, raises the page and focuses the transcript" do
    reg = Crysterm::Chat::TaskRegistry.new
    agent reg, "alpha"
    b = agent reg, "beta"
    fleet = new_fleet reg

    tr = fleet.open b
    fleet.roster.current_index.should eq 1
    fleet.pages.current_widget.same?(tr).should be_true
    tr.focused?.should be_true
    fleet.current_task.should be b
  end

  it "Escape-cancel on a settled row does not steal focus into its page" do
    reg = Crysterm::Chat::TaskRegistry.new
    a = agent reg, "alpha"
    reg.transition a, Crysterm::Chat::Task::State::Ok
    fleet = new_fleet reg
    fleet.roster.focus

    # The task is finished, so TaskStrip's Escape falls through to the stock
    # item-view cancel — which emits ItemActivated too; the fleet must not
    # treat that as an open.
    fleet.roster.on_keypress kp(key: ::Tput::Key::Escape)
    fleet.roster.focused?.should be_true
    fleet.context?(a).not_nil!.focused?.should be_false
  end

  it "Escape inside a transcript returns focus to the roster" do
    reg = Crysterm::Chat::TaskRegistry.new
    a = agent reg, "alpha"
    fleet = new_fleet reg

    tr = fleet.open a
    tr.focused?.should be_true

    e = kp key: ::Tput::Key::Escape
    tr.emit e
    e.accepted?.should be_true
    fleet.roster.focused?.should be_true
    tr.focused?.should be_false
  end

  it "destroys a removed task's context and falls back to the survivors" do
    reg = Crysterm::Chat::TaskRegistry.new
    a = agent reg, "alpha"
    b = agent reg, "beta"
    fleet = new_fleet reg
    fleet.open b
    fleet.pages.count.should eq 3

    reg.delete b
    fleet.context?(b).nil?.should be_true
    fleet.pages.count.should eq 2
    # Selection reclamps to the remaining row; the page follows it.
    fleet.pages.current_widget.same?(fleet.context?(a)).should be_true
    fleet.current_task.should be a

    reg.delete a
    fleet.pages.count.should eq 1
    fleet.pages.current_widget.same?(fleet.placeholder).should be_true
    fleet.current_task.should be_nil
  end

  it "finished tasks keep their transcript; only removal drops it" do
    reg = Crysterm::Chat::TaskRegistry.new
    a = agent reg, "alpha"
    fleet = new_fleet reg
    tr = fleet.transcript_for a
    tr.append Crysterm::Widget::Chat::Transcript::Kind::Prose, "done deal"

    reg.transition a, Crysterm::Chat::Task::State::Ok
    fleet.context?(a).same?(tr).should be_true
    tr.entries.size.should eq 1
  end

  it "header tracks agent count, running/active counts and peak concurrency" do
    reg = Crysterm::Chat::TaskRegistry.new
    fleet = new_fleet reg

    a = agent reg, "alpha"
    b = agent reg, "beta"
    reg.add "Bash(make)"
    fleet.header.content.should contain "2 agents"
    fleet.header.content.should contain "3 active"

    reg.transition a, Crysterm::Chat::Task::State::Running
    reg.transition b, Crysterm::Chat::Task::State::Running
    fleet.header.content.should contain "2 running"
    fleet.header.content.should contain "peak 2"

    reg.transition a, Crysterm::Chat::Task::State::Ok
    reg.transition b, Crysterm::Chat::Task::State::Fail, exit_code: 1
    fleet.header.content.should contain "0 running"
    # Peak is a lifetime high-water mark, not the current count.
    fleet.header.content.should contain "peak 2"
    fleet.header.content.should contain "1 active"
  end

  it "converges header and roster on stop_all's single coalesced Reset" do
    reg = Crysterm::Chat::TaskRegistry.new
    a = agent reg, "alpha"
    b = agent reg, "beta"
    fleet = new_fleet reg
    reg.transition a, Crysterm::Chat::Task::State::Running
    reg.transition b, Crysterm::Chat::Task::State::Running
    fleet.header.content.should contain "2 running"

    events = 0
    reg.on(Crysterm::Event::ListChanged) { events += 1 }
    reg.stop_all
    events.should eq 1
    fleet.header.content.should contain "0 running"
    fleet.header.content.should contain "0 active"
    fleet.header.content.should contain "peak 2"
    fleet.roster.item_texts[0].should contain "cancelled"
    fleet.roster.item_texts[1].should contain "cancelled"
  end

  it "singularizes the agent readout" do
    reg = Crysterm::Chat::TaskRegistry.new
    agent reg, "solo"
    fleet = new_fleet reg
    fleet.header.content.should contain "1 agent "
  end
end
