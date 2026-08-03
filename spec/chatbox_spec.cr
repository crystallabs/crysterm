require "./spec_helper"

include Crysterm

# `Widget::Chat::ChatBox`: the assembled chat composer — transcript/input/
# task-strip/status-line composition, the submit echo+busy flow, the
# rebindable composer keymap (mode cycle, strip toggle, expand/collapse,
# interrupt, stop-all), registry-fed task counts and completion events, the
# shared-registry autocomplete, and the fleet-view summon.

private alias ChatBox = Crysterm::Widget::Chat::ChatBox
private alias Transcript = Crysterm::Widget::Chat::Transcript
private alias Mode = Crysterm::Chat::Mode
private alias Task = Crysterm::Chat::Task

# A rendered full-window composer with the input focused (its read session
# live), ready for synthesized keystrokes.
private def build(width = 80, height = 24, **opts)
  s = headless_screen(width, height)
  chat = ChatBox.new **opts.merge({parent: s, left: 0, top: 0, width: "100%", height: "100%"})
  chat.focus_input
  s.repaint
  {s, chat}
end

# Emits a keystroke on *w*, running its full handler chain (autocomplete
# interceptor, composer keymap, editing listener) in order.
private def press(w, char : Char = '\0', key : ::Tput::Key? = nil)
  w.emit Crysterm::Event::KeyPress, kp(char, key)
end

private def type_str(w, str : String)
  str.each_char { |c| press w, c }
end

private def press_enter(w)
  press w, '\r', ::Tput::Key::Enter
end

describe Crysterm::Widget::Chat::ChatBox do
  it "composes transcript/input/strip/status vertically, transcript filling" do
    s, chat = build
    s.repaint

    # Strip starts hidden (no tasks), so three slots: transcript fills,
    # input auto-grows to one content row + border, status takes one row.
    chat.task_strip.hidden?.should be_true
    chat.input.aheight.should eq 3
    chat.status_line.aheight.should eq 1
    chat.transcript.aheight.should eq 24 - 3 - 1

    chat.transcript.atop.should eq 0
    chat.input.atop.should eq chat.transcript.atop + chat.transcript.aheight
    chat.status_line.atop.should eq chat.input.atop + chat.input.aheight

    # All spans stretch the full width.
    chat.transcript.awidth.should eq 80
    chat.input.awidth.should eq 80
  end

  it "submit echoes into the transcript, goes busy and re-emits Submitted" do
    _s, chat = build
    submitted = [] of String
    chat.on(Crysterm::Event::Submitted) { |e| submitted << e.value }

    type_str chat.input, "hello there"
    press_enter chat.input

    chat.transcript.entries.size.should eq 1
    chat.transcript.entries[0].kind.prose?.should be_true
    chat.transcript.entries[0].text.should eq "hello there"
    chat.input.value.should eq ""
    chat.busy?.should be_true
    submitted.should eq ["hello there"]

    chat.idle
    chat.busy?.should be_false
  end

  it "Shift+Tab cycles the mode: badge, ModeChanged and input border accent" do
    _s, chat = build
    seen = [] of Mode
    chat.on(Crysterm::Event::ModeChanged) { |e| seen << e.mode }

    press chat.input, key: ::Tput::Key::ShiftTab
    chat.mode.should eq Mode::AutoAccept
    chat.status_line.message.should contain "accept edits on"
    chat.input.state_style.border.fg.should eq rgb("magenta")

    press chat.input, key: ::Tput::Key::ShiftTab
    chat.mode.should eq Mode::Plan
    chat.input.state_style.border.fg.should eq rgb("cyan")

    2.times { press chat.input, key: ::Tput::Key::ShiftTab }
    chat.mode.should eq Mode::Normal # wrapped
    chat.input.state_style.border.fg.should be_nil

    seen.should eq [Mode::AutoAccept, Mode::Plan, Mode::Bypass, Mode::Normal]
    # The keystrokes never leaked into the buffer.
    chat.input.value.should eq ""
  end

  it "shows the strip when tasks arrive, syncs task_count, and Ctrl+B toggles both ways" do
    s, chat = build

    chat.task_strip.hidden?.should be_true
    chat.status_line.task_count.should eq 0

    a = chat.add_task "Bash(npm test)"
    b = chat.add_task "explorer", Task::Kind::Agent, state: :running
    s.repaint

    chat.task_strip.visible?.should be_true
    chat.task_strip.aheight.should eq 2 # one row per task
    chat.status_line.task_count.should eq 2
    chat.status_line.message.should contain "2 tasks running"

    # Global Ctrl+B from inside the input hides the strip...
    press chat.input, key: ::Tput::Key::CtrlB
    chat.task_strip.hidden?.should be_true
    chat.tasks_hidden?.should be_true

    # ...and (composer-level, since the hidden widget gets no keys) re-shows it.
    press chat.input, key: ::Tput::Key::CtrlB
    chat.task_strip.visible?.should be_true
    chat.tasks_hidden?.should be_false

    # A finished task leaves the count; an emptied registry re-hides the strip.
    chat.tasks.transition a, Task::State::Ok, exit_code: 0
    chat.tasks.transition b, Task::State::Cancelled
    chat.status_line.task_count.should eq 0
  end

  it "emits TaskCompleted once per task reaching a terminal state" do
    _s, chat = build
    done = [] of Task
    chat.on(Crysterm::Event::TaskCompleted) { |e| done << e.task }

    a = chat.add_task "one", state: :running
    b = chat.add_task "two", state: :running
    done.should be_empty

    chat.tasks.transition a, Task::State::Ok, exit_code: 0
    done.should eq [a]

    # Further updates to a settled task don't re-fire.
    chat.tasks.touch a
    done.should eq [a]

    chat.tasks.transition b, Task::State::Fail, exit_code: 1
    done.should eq [a, b]
  end

  it "stop_all's single coalesced event still yields TaskCompleted per task" do
    _s, chat = build
    done = [] of Task
    chat.on(Crysterm::Event::TaskCompleted) { |e| done << e.task }
    a = chat.add_task "one", state: :running
    b = chat.add_task "two", state: :running

    events = 0
    chat.tasks.on(Crysterm::Event::ListChanged) { events += 1 }
    chat.tasks.stop_all
    events.should eq 1
    done.should eq [a, b] # registry order
    chat.status_line.task_count.should eq 0
  end

  it "Ctrl+K stops all from the composer tier but stays readline inside the input" do
    _s, chat = build
    a = chat.add_task "one", state: :running

    # Inside the reading input the editor owns Ctrl+K (kill to line end).
    press chat.input, key: ::Tput::Key::CtrlK
    a.state.running?.should be_true

    # At the composer tier (bubbled from a non-consuming descendant) it fires.
    press chat, key: ::Tput::Key::CtrlK
    a.state.cancelled?.should be_true
  end

  it "opens the autocomplete menu on / with the built-in slash commands" do
    _s, chat = build

    type_str chat.input, "/"
    chat.autocomplete.open?.should be_true
    pop = chat.autocomplete.@popup.not_nil!
    pop.items.size.should eq ChatBox::SLASH_COMMANDS.size
    pop.items.first.should start_with "/help"

    type_str chat.input, "mo"
    pop.items.first.should start_with "/model"

    # Accepting completes the token in place; no submit happens.
    press chat.input, '\t', ::Tput::Key::Tab
    chat.input.value.should eq "/model "
    chat.transcript.entries.should be_empty
  end

  it "executes local slash commands on submit: /mode cycles, /tasks toggles, no busy" do
    _s, chat = build
    submitted = [] of String
    chat.on(Crysterm::Event::Submitted) { |e| submitted << e.value }
    chat.add_task "one"

    # Typing "/" opens the completion menu, whose Enter would accept the
    # highlighted row instead of submitting — Esc first dismisses it (and
    # only it: the composer's interrupt leaves the typed text alone).
    type_str chat.input, "/mode"
    press chat.input, '\e', ::Tput::Key::Escape
    chat.input.value.should eq "/mode"
    press_enter chat.input
    chat.mode.should eq Mode::AutoAccept
    chat.busy?.should be_false
    submitted.should be_empty
    chat.transcript.entries.size.should eq 1 # still echoed

    type_str chat.input, "/tasks"
    press chat.input, '\e', ::Tput::Key::Escape
    press_enter chat.input
    chat.tasks_hidden?.should be_true
    chat.busy?.should be_false
    submitted.should be_empty

    # An unknown slash command flows to the application like any text.
    type_str chat.input, "/frobnicate"
    press_enter chat.input
    submitted.should eq ["/frobnicate"]
    chat.busy?.should be_true
    chat.idle
  end

  it "Esc interrupts: busy emits Cancelled and idles; else clears the input; read session survives" do
    _s, chat = build
    cancels = 0
    chat.on(Crysterm::Event::Cancelled) { cancels += 1 }

    chat.busy "Pondering"
    press chat.input, '\e', ::Tput::Key::Escape
    chat.busy?.should be_false
    cancels.should eq 1

    type_str chat.input, "half a thought"
    press chat.input, '\e', ::Tput::Key::Escape
    chat.input.value.should eq ""
    cancels.should eq 1

    # Idle + empty: swallowed, and the read session is still alive — typing
    # and submitting still works.
    press chat.input, '\e', ::Tput::Key::Escape
    type_str chat.input, "still here"
    press_enter chat.input
    chat.transcript.entries.last.text.should eq "still here"
    chat.idle
  end

  it "Ctrl+O collapses/expands the latest collapsible entry from inside the input" do
    _s, chat = build
    long = (1..15).join('\n') { |i| "line #{i}" }
    entry = chat.append_tool_result long, chat.append_tool_call("Bash(seq 15)")

    collapsed = [] of Int32
    expanded = [] of Int32
    chat.transcript.on(Crysterm::Event::Collapsed) { |e| collapsed << e.index }
    chat.transcript.on(Crysterm::Event::Expanded) { |e| expanded << e.index }

    entry.collapsed.should be_true
    press chat.input, key: ::Tput::Key::CtrlO
    expanded.should eq [1]
    entry.collapsed.should be_false

    press chat.input, key: ::Tput::Key::CtrlO
    collapsed.should eq [1]
    entry.collapsed.should be_true
  end

  it "the keymap is rebindable" do
    _s, chat = build

    chat.unbind ::Tput::Key::ShiftTab
    press chat.input, key: ::Tput::Key::ShiftTab
    chat.mode.should eq Mode::Normal

    chat.bind ::Tput::Key::F2, :cycle_mode
    press chat.input, key: ::Tput::Key::F2
    chat.mode.should eq Mode::AutoAccept
  end

  it "activating a strip row summons the fleet view; roster cancel dismisses it" do
    s, chat = build
    task = chat.add_task "explorer", Task::Kind::Agent, state: :running
    s.repaint

    chat.fleet.nil?.should be_true # nil? form: widget-typed be_nil hangs the compiler (inspect blowup)
    chat.task_strip.focus
    chat.task_strip.emit Crysterm::Event::KeyPress, kp('\r', ::Tput::Key::Enter)

    fleet = chat.fleet.not_nil!
    fleet.visible?.should be_true
    fleet.current_task.should be task

    # Esc on the roster first interrupts the running task (TaskStrip's own
    # key), then — with nothing left to interrupt — cancels out of the fleet.
    fleet.roster.focus
    fleet.roster.emit Crysterm::Event::KeyPress, kp('\e', ::Tput::Key::Escape)
    task.state.cancelled?.should be_true
    fleet.visible?.should be_true

    fleet.roster.emit Crysterm::Event::KeyPress, kp('\e', ::Tput::Key::Escape)
    fleet.visible?.should be_false
    chat.input.focused?.should be_true
  end
end
