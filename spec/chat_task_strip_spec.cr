require "./spec_helper"

include Crysterm

# `Chat::TaskRegistry` (observable task roster) + `Widget::Chat::TaskStrip`
# (the tasks/agents strip bound to it): reactive row patching, state-glyph
# transitions, the Ctrl+B/Ctrl+K/Esc keys and the explicit-clock spinner.

private def strip_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false,
    optimization: Crysterm::OptimizationFlag::DamageTracking)
end

# The window stays reachable through the strip's parent chain, so returning
# just the strip keeps it alive for the example's duration.
private def new_strip(registry = Crysterm::Chat::TaskRegistry.new)
  Crysterm::Widget::Chat::TaskStrip.new registry,
    parent: strip_screen, top: 0, left: 0, width: 60, height: 6, animate: false
end

describe Crysterm::Chat::TaskRegistry do
  it "adds tasks with unique monotonic ids and emits Insert" do
    reg = Crysterm::Chat::TaskRegistry.new
    ops = [] of Crysterm::Reactive::ListOp
    reg.on(Crysterm::Event::ListChanged) { |e| ops << e.op }
    a = reg.add "Bash(npm test)"
    b = reg.add "explorer", Crysterm::Chat::Task::Kind::Agent
    a.id.should_not eq b.id
    b.id.should be > a.id
    reg.size.should eq 2
    ops.should eq [Crysterm::Reactive::ListOp::Insert, Crysterm::Reactive::ListOp::Insert]
    reg.find(a.id).should be a
    reg.index_of(b).should eq 1
  end

  it "transition mutates state/exit_code and emits Update at the task's row" do
    reg = Crysterm::Chat::TaskRegistry.new
    a = reg.add "one"
    b = reg.add "two"
    seen = [] of {Crysterm::Reactive::ListOp, Int32}
    reg.on(Crysterm::Event::ListChanged) { |e| seen << {e.op, e.index} }
    reg.transition b, Crysterm::Chat::Task::State::Running
    reg.transition b, Crysterm::Chat::Task::State::Fail, exit_code: 2
    b.state.fail?.should be_true
    b.exit_code.should eq 2
    a.state.pending?.should be_true
    seen.should eq [
      {Crysterm::Reactive::ListOp::Update, 1},
      {Crysterm::Reactive::ListOp::Update, 1},
    ]
  end

  it "update yields for mutation and notifies; touch reports unknown tasks" do
    reg = Crysterm::Chat::TaskRegistry.new
    a = reg.add "one"
    notified = 0
    reg.on(Crysterm::Event::ListChanged) { notified += 1 }
    reg.update(a, &.detail=("step 2/5")).should be_true
    a.detail.should eq "step 2/5"
    notified.should eq 1
    stray = Crysterm::Chat::Task.new 999, "stray"
    reg.touch(stray).should be_false
  end

  it "stop_all cancels only unfinished tasks" do
    reg = Crysterm::Chat::TaskRegistry.new
    done = reg.add "done"
    run = reg.add "run"
    pend = reg.add "pend"
    reg.transition done, Crysterm::Chat::Task::State::Ok
    reg.transition run, Crysterm::Chat::Task::State::Running
    reg.active_count.should eq 2
    reg.stop_all
    done.state.ok?.should be_true
    run.state.cancelled?.should be_true
    pend.state.cancelled?.should be_true
    reg.active_count.should eq 0
    reg.running_count.should eq 0
  end

  it "stop_all coalesces into a single Reset event; a no-op stop_all emits nothing" do
    reg = Crysterm::Chat::TaskRegistry.new
    a = reg.add "a"
    b = reg.add "b"
    reg.transition a, Crysterm::Chat::Task::State::Running
    ops = [] of Crysterm::Reactive::ListOp
    reg.on(Crysterm::Event::ListChanged) { |e| ops << e.op }
    reg.stop_all
    ops.should eq [Crysterm::Reactive::ListOp::Reset]
    a.state.cancelled?.should be_true
    b.state.cancelled?.should be_true
    # Everything already finished: no event at all.
    reg.stop_all
    ops.size.should eq 1
  end

  it "touch/index_of/find target the right row after structural churn" do
    reg = Crysterm::Chat::TaskRegistry.new
    a = reg.add "a"
    b = reg.add "b"
    c = reg.add "c"
    # Warm the id→row memo, then shift every row with a removal.
    reg.touch(b).should be_true
    reg.delete a
    seen = [] of {Crysterm::Reactive::ListOp, Int32}
    reg.on(Crysterm::Event::ListChanged) { |e| seen << {e.op, e.index} }
    reg.touch(c).should be_true
    seen.should eq [{Crysterm::Reactive::ListOp::Update, 1}]
    reg.index_of(b).should eq 0
    reg.index_of(c).should eq 1
    reg.find(c.id).should be c
    reg.find(a.id).should be_nil
  end
end

describe Crysterm::Widget::Chat::TaskStrip do
  it "renders one row per task and follows add/update/remove" do
    reg = Crysterm::Chat::TaskRegistry.new
    reg.add "Bash(npm test)"
    strip = new_strip reg
    strip.item_texts.size.should eq 1
    strip.item_texts[0].should contain "Bash(npm test)"

    b = reg.add "explorer"
    strip.item_texts.size.should eq 2
    strip.item_texts[1].should contain "explorer"

    reg.transition b, Crysterm::Chat::Task::State::Running
    strip.item_texts[1].should contain "running…"

    reg.delete b
    strip.item_texts.size.should eq 1
    strip.item_texts[0].should contain "Bash(npm test)"
  end

  it "shows the state glyph per lifecycle state, colored per the shared class-color defaults" do
    reg = Crysterm::Chat::TaskRegistry.new
    t = reg.add "job"
    strip = new_strip reg
    # Pending/cancelled follow the shared DEFAULT_CLASS_COLORS (gray), the
    # same table transcript entries resolve through.
    strip.item_texts[0].should contain "{gray-fg}○{/gray-fg} job {gray-fg}queued{/gray-fg}"

    reg.transition t, Crysterm::Chat::Task::State::Running
    # Spinner frame 0 is the middot; running rows are cyan.
    strip.item_texts[0].should contain "{cyan-fg}·{/cyan-fg} job"
    strip.item_texts[0].should contain "running…"

    reg.transition t, Crysterm::Chat::Task::State::Ok
    strip.item_texts[0].should contain "{green-fg}✓{/green-fg} job"

    reg.transition t, Crysterm::Chat::Task::State::Fail, exit_code: 1
    strip.item_texts[0].should contain "{red-fg}✗{/red-fg} job"
    strip.item_texts[0].should contain "exit 1"

    reg.transition t, Crysterm::Chat::Task::State::Cancelled
    strip.item_texts[0].should contain "{gray-fg}✗{/gray-fg} job {gray-fg}cancelled{/gray-fg}"
  end

  it "renders detail between label and state note" do
    reg = Crysterm::Chat::TaskRegistry.new
    t = reg.add "agent", Crysterm::Chat::Task::Kind::Agent, detail: "reading specs"
    strip = new_strip reg
    strip.item_texts[0].should contain "agent · reading specs"
    strip.item_texts[0].should contain "queued"
    reg.update(t, &.detail=("writing code"))
    strip.item_texts[0].should contain "agent · writing code"
  end

  it "set_class_color rethemes existing rows" do
    reg = Crysterm::Chat::TaskRegistry.new
    t = reg.add "job"
    reg.transition t, Crysterm::Chat::Task::State::Ok
    strip = new_strip reg
    strip.item_texts[0].should contain "{green-fg}✓{/green-fg} job"

    strip.set_class_color Crysterm::Chat::Glyphs::CLASS_OK, "magenta"
    strip.item_texts[0].should contain "{magenta-fg}✓{/magenta-fg} job"

    # Clearing the class renders the row uncolored.
    strip.set_class_color Crysterm::Chat::Glyphs::CLASS_OK, nil
    strip.item_texts[0].should contain "✓ job"
    strip.item_texts[0].should_not contain "-fg}"
  end

  it "advances the spinner frame on step, only for running rows" do
    reg = Crysterm::Chat::TaskRegistry.new
    run = reg.add "spin"
    reg.add "idle"
    reg.transition run, Crysterm::Chat::Task::State::Running
    strip = new_strip reg

    strip.item_texts[0].should contain "{cyan-fg}·{/cyan-fg} spin"
    idle_row = strip.item_texts[1]

    strip.step
    strip.item_texts[0].should contain "{cyan-fg}✢{/cyan-fg} spin"
    strip.step
    strip.item_texts[0].should contain "{cyan-fg}✳{/cyan-fg} spin"
    strip.item_texts[1].should eq idle_row

    # The frame counter wraps around the frame set.
    frames = Crysterm::Chat::Glyphs::SPINNER_FRAMES.size
    (frames - 2).times { strip.step }
    strip.item_texts[0].should contain "{cyan-fg}·{/cyan-fg} spin"
  end

  it "Ctrl+K cancels every unfinished task" do
    reg = Crysterm::Chat::TaskRegistry.new
    a = reg.add "a"
    b = reg.add "b"
    reg.transition a, Crysterm::Chat::Task::State::Running
    strip = new_strip reg

    e = kp key: ::Tput::Key::CtrlK
    strip.on_keypress e
    e.accepted?.should be_true
    a.state.cancelled?.should be_true
    b.state.cancelled?.should be_true
    strip.item_texts[0].should contain "cancelled"
    strip.item_texts[1].should contain "cancelled"
  end

  it "Esc interrupts the selected row's task" do
    reg = Crysterm::Chat::TaskRegistry.new
    a = reg.add "a"
    b = reg.add "b"
    reg.transition a, Crysterm::Chat::Task::State::Running
    reg.transition b, Crysterm::Chat::Task::State::Running
    strip = new_strip reg

    strip.current_index = 1
    e = kp key: ::Tput::Key::Escape
    strip.on_keypress e
    e.accepted?.should be_true
    b.state.cancelled?.should be_true
    a.state.running?.should be_true
    strip.item_texts[1].should contain "cancelled"
  end

  it "Esc on a finished task interrupts nothing" do
    reg = Crysterm::Chat::TaskRegistry.new
    a = reg.add "a"
    reg.transition a, Crysterm::Chat::Task::State::Ok
    strip = new_strip reg

    strip.interrupt_current.should be_false
    a.state.ok?.should be_true
  end

  it "Ctrl+B toggles the strip's visibility" do
    reg = Crysterm::Chat::TaskRegistry.new
    reg.add "a"
    strip = new_strip reg

    strip.visible?.should be_true
    e = kp key: ::Tput::Key::CtrlB
    strip.on_keypress e
    e.accepted?.should be_true
    strip.visible?.should be_false
    strip.on_keypress kp(key: ::Tput::Key::CtrlB)
    strip.visible?.should be_true
  end

  it "escapes braces in labels and details so rows cannot inject tags" do
    reg = Crysterm::Chat::TaskRegistry.new
    reg.add "Bash({red-fg}x{/red-fg})"
    strip = new_strip reg
    strip.item_texts[0].should contain "{open}red-fg{close}"
  end
end
