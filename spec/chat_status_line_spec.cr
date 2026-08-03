require "./spec_helper"

include Crysterm

# `Widget::Chat::StatusLine`: the `Chat::Mode` permission machine cycled by
# Shift+Tab, the badge / task-count / hint strip, and the busy spinner
# (elapsed readout + interrupt hint) shown while the backend works.

private alias StatusLine = Crysterm::Widget::Chat::StatusLine
private alias Mode = Crysterm::Chat::Mode
private alias ChatGlyphs = Crysterm::Chat::Glyphs

private def shift_tab
  Crysterm::Event::KeyPress.new '\0', Tput::Key::ShiftTab
end

describe Crysterm::Widget::Chat::StatusLine do
  it "cycles modes in order on Shift+Tab, wrapping, and emits CurrentChanged" do
    s = headless_screen(60, 10)
    sl = StatusLine.new parent: s, bottom: 0, left: 0, width: "100%", height: 1

    sl.mode.should eq Mode::Normal
    seen = [] of Int32
    sl.on(Crysterm::Event::CurrentChanged) { |e| seen << e.index }

    sl.emit shift_tab
    sl.mode.should eq Mode::AutoAccept
    sl.emit shift_tab
    sl.mode.should eq Mode::Plan
    sl.emit shift_tab
    sl.mode.should eq Mode::Bypass
    sl.emit shift_tab
    sl.mode.should eq Mode::Normal # wrapped

    seen.should eq [
      Mode::AutoAccept.value, Mode::Plan.value,
      Mode::Bypass.value, Mode::Normal.value,
    ]

    # Other keys pass through untouched.
    sl.emit Crysterm::Event::KeyPress.new('\t', Tput::Key::Tab)
    sl.mode.should eq Mode::Normal
  end

  it "pins the per-mode label, color and cycle-order table" do
    Mode::Normal.label.should eq ""
    Mode::AutoAccept.label.should eq "⏵⏵ accept edits on"
    Mode::Plan.label.should eq "⏸ plan mode on"
    Mode::Bypass.label.should eq "⏵⏵ bypass permissions on"

    Mode::Normal.color.should be_nil
    Mode::AutoAccept.color.should eq "magenta"
    Mode::Plan.color.should eq "cyan"
    Mode::Bypass.color.should eq "red"

    Mode::Normal.next.should eq Mode::AutoAccept
    Mode::AutoAccept.next.should eq Mode::Plan
    Mode::Plan.next.should eq Mode::Bypass
    Mode::Bypass.next.should eq Mode::Normal
  end

  it "shows the styled badge, task count and hints middot-separated" do
    s = headless_screen(80, 10)
    sl = StatusLine.new parent: s, bottom: 0, left: 0, width: "100%", height: 1

    sl.message.should eq "" # Normal: no badge, nothing else set

    sl.mode = :auto_accept
    sl.message.should eq "{magenta-fg}⏵⏵ accept edits on{/magenta-fg}"

    sl.task_count = 2
    sl.hints = ["ctrl+o to expand"]
    parts = sl.message.split " #{ChatGlyphs::MIDDOT} "
    parts.size.should eq 3
    parts[0].should contain "accept edits on"
    parts[1].should eq "2 tasks running"
    parts[2].should eq "ctrl+o to expand"

    sl.task_count = 1
    sl.message.should contain "1 task running" # singular

    sl.mode = :plan
    sl.message.should contain "{cyan-fg}⏸ plan mode on{/cyan-fg}"

    sl.mode = :normal
    sl.task_count = 0
    sl.hints = [] of String
    sl.message.should eq ""
  end

  it "busy shows the spinner with label, elapsed and interrupt hint; idle hides it" do
    s = headless_screen(80, 10)
    sl = StatusLine.new parent: s, bottom: 0, left: 0, width: "100%", height: 1

    sl.busy?.should be_false
    sl.spinner.hidden?.should be_true

    sl.busy "Pondering"
    sl.busy?.should be_true
    sl.spinner.hidden?.should be_false
    s.render

    line = sl.spinner.content
    line.should contain "Pondering"
    line.should contain ChatGlyphs::SPINNER_FRAMES[0]
    line.should match /\(\d+s #{ChatGlyphs::MIDDOT} esc to interrupt\)/

    sl.idle
    sl.busy?.should be_false
    sl.spinner.hidden?.should be_true
    s.render

    # Re-entering busy restarts the elapsed clock and takes a fresh label.
    sl.busy
    sl.busy?.should be_true
    sl.busy_elapsed.total_seconds.should be < 1.0
    s.render
    sl.spinner.content.should contain "Thinking#{ChatGlyphs::ELLIPSIS}"
    sl.idle
  end

  it "advances sparkle frames on step, refreshing the busy line each frame" do
    s = headless_screen(80, 10)
    sl = StatusLine.new parent: s, bottom: 0, left: 0, width: "100%", height: 1
    frames = ChatGlyphs::SPINNER_FRAMES.to_a

    sl.busy "Working"
    sl.spinner.icon.content.should eq frames[0]

    sl.spinner.step
    sl.spinner.icon.content.should eq frames[1]
    sl.spinner.step
    sl.spinner.icon.content.should eq frames[2]

    # Wraps around the frame set.
    (frames.size - 2).times { sl.spinner.step }
    sl.spinner.icon.content.should eq frames[0]

    # Every step recomputes the busy line, keeping the readout live.
    s.render
    sl.spinner.content.should match /Working \(\d+s #{ChatGlyphs::MIDDOT} esc to interrupt\)/
    sl.idle
  end
end
