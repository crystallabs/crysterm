require "./spec_helper"

include Crysterm

# Specs for the §7.1/§7.2 efficiency cluster:
#
# §7.1 — capability-gated escapes: DEC 2026 synchronized output and OSC 8
#        hyperlinks resolve an `AutoToggle` policy against `tty?` plus the
#        identity-derived `Tput::Features` flags, instead of being emitted
#        unconditionally; `mouse.cursor_shape` gains the same auto policy.
# §7.2 — idle efficiency: `window.send_focus` defaults on, and
#        `render.pause_when_unfocused` parks the render loop while the
#        terminal window is unfocused (DEC 1004 blur report), resuming with a
#        repaint on focus-in.

private def gating_window(output = IO::Memory.new, width = 30, height = 4)
  Crysterm::Window.new(
    input: IO::Memory.new, output: output, error: IO::Memory.new,
    width: width, height: height)
end

# An anchor whose painted cells carry a link id (the OSC 8 source).
private def gating_anchor(s, url = "https://example.org")
  te = Crysterm::Widget::TextEdit.new parent: s, left: 0, top: 0, width: 30,
    height: 4, content: "click here"
  te.document.cursor(0, 5).set_char_format(Crysterm::TextCharFormat.new(anchor_href: url))
  te
end

describe "§7.1: DEC 2026 synchronized output gating" do
  it "auto resolves off for a non-tty output even with the feature flag set" do
    s = gating_window
    begin
      s.synchronized_output.auto?.should be_true # config default
      s.screen.tput.features.synchronized_output = true
      s.synchronized_output?.should be_false # IO::Memory is not a tty
    ensure
      s.destroy
    end
  end

  it "auto emits no 2026 bracket on a headless frame" do
    outp = IO::Memory.new
    s = gating_window(outp)
    begin
      Widget::Box.new parent: s, left: 0, top: 0, width: 10, height: 1, content: "x"
      s.repaint
      outp.to_s.should_not contain "\e[?2026h"
    ensure
      s.destroy
    end
  end

  it "on forces the 2026 bracket regardless of tty/identity" do
    outp = IO::Memory.new
    s = gating_window(outp)
    begin
      s.synchronized_output = AutoToggle::On
      Widget::Box.new parent: s, left: 0, top: 0, width: 10, height: 1, content: "x"
      s.repaint
      text = outp.to_s
      text.should contain "\e[?2026h"
      text.should contain "\e[?2026l"
    ensure
      s.destroy
    end
  end

  it "bool assignment maps onto the policy" do
    s = gating_window
    begin
      s.synchronized_output = true
      s.synchronized_output.on?.should be_true
      s.synchronized_output = false
      s.synchronized_output.off?.should be_true
    ensure
      s.destroy
    end
  end
end

describe "§7.1: OSC 8 hyperlink gating" do
  it "auto registers link ids but emits no OSC 8 on a non-tty" do
    outp = IO::Memory.new
    s = gating_window(outp)
    begin
      s.hyperlinks.auto?.should be_true # config default
      gating_anchor s
      s.repaint
      # Registration is policy-gated, not emission-gated: the cell carries its
      # link id even though no escape reached the (non-tty) output.
      s.cell_rows[0][0].link.should_not eq 0
      outp.to_s.should_not contain "\e]8;;"
    ensure
      s.destroy
    end
  end

  it "off stops registration entirely" do
    s = gating_window
    begin
      s.hyperlinks = AutoToggle::Off
      s.link_id("https://example.org").should eq 0
    ensure
      s.destroy
    end
  end

  it "on emits the OSC 8 escapes" do
    outp = IO::Memory.new
    s = gating_window(outp)
    begin
      s.hyperlinks = AutoToggle::On
      gating_anchor s
      s.repaint
      outp.to_s.should contain "\e]8;;https://example.org\e\\"
    ensure
      s.destroy
    end
  end
end

describe "§7.1: mouse.cursor_shape auto policy" do
  it "auto resolves off headless; explicit values force" do
    s = gating_window
    begin
      s.mouse_cursor_shaping.auto?.should be_true # config default
      s.mouse_cursor_shaping?.should be_false     # non-tty
      s.mouse_cursor_shaping = true
      s.mouse_cursor_shaping?.should be_true
      s.mouse_cursor_shaping = AutoToggle::Off
      s.mouse_cursor_shaping?.should be_false
    ensure
      s.destroy
    end
  end
end

describe "§7.1: identity-derived capability tables" do
  it "derives 2026/OSC 8 from a supporting identity and OSC 22 from xterm-class" do
    s = gating_window
    begin
      e = s.screen.tput.emulator?
      fail "no emulator identity" unless e
      # Zero every identity flag the tables read, so the box's real env
      # doesn't leak into the assertions.
      {% for flag in %w[kitty wezterm ghostty iterm2 foot konsole xterm tmux] %}
        e.{{ flag.id }} = false
      {% end %}
      env = {} of String => String
      Terminal::Capabilities.synchronized_output?(e, env).should be_false
      Terminal::Capabilities.hyperlinks?(e, env).should be_false
      Terminal::Capabilities.pointer_shape?(e).should be_false

      e.kitty = true
      Terminal::Capabilities.synchronized_output?(e, env).should be_true
      Terminal::Capabilities.hyperlinks?(e, env).should be_true
      Terminal::Capabilities.pointer_shape?(e).should be_true

      e.kitty = false
      e.xterm = true
      # Genuine xterm: OSC 22 yes, 2026/OSC 8 no.
      Terminal::Capabilities.pointer_shape?(e).should be_true
      Terminal::Capabilities.synchronized_output?(e, env).should be_false
      Terminal::Capabilities.hyperlinks?(e, env).should be_false
    ensure
      s.destroy
    end
  end
end

describe "§7.2: focus-driven render pause" do
  it "tracks terminal focus from DEC 1004 reports" do
    s = gating_window
    begin
      s.terminal_focused?.should be_true # assumed focused until told otherwise
      s.dispatch_mouse ::Tput::Mouse::Event.blur
      s.terminal_focused?.should be_false
      s.dispatch_mouse ::Tput::Mouse::Event.focus
      s.terminal_focused?.should be_true
    ensure
      s.destroy
    end
  end

  it "pauses frame production while unfocused and resumes with a repaint on focus-in" do
    outp = IO::Memory.new
    s = gating_window(outp)
    begin
      s.pause_when_unfocused?.should be_true # config default
      box = Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 1,
        content: "ORIG"
      s.repaint
      s.dispatch_mouse ::Tput::Mouse::Event.blur
      outp.clear

      # A mutation while unfocused rings the doorbell, but the parked loop
      # must consume the ring without building or writing a frame.
      box.content = "CHANGED"
      s.update
      sleep 80.milliseconds
      outp.to_s.should eq ""

      # Focus-in resumes the loop and repaints the deferred change.
      s.dispatch_mouse ::Tput::Mouse::Event.focus
      sleep 80.milliseconds
      outp.to_s.should contain "CHANGED"
    ensure
      s.destroy
    end
  end

  it "does not pause when the knob is off" do
    outp = IO::Memory.new
    s = gating_window(outp)
    begin
      s.pause_when_unfocused = false
      box = Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 1,
        content: "ORIG"
      s.repaint
      s.dispatch_mouse ::Tput::Mouse::Event.blur
      outp.clear

      box.content = "CHANGED"
      s.update
      sleep 80.milliseconds
      outp.to_s.should contain "CHANGED"
    ensure
      s.destroy
    end
  end
end
