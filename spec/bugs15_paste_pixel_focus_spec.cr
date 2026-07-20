require "./spec_helper"

include Crysterm

# Regression specs for the BUGS15 formerly-deferred findings #6/#7, #16, #63.
#
# #6/#7: a bare `Screen#enable_mouse` re-assert (as `Window#listen` and
#        `Window#register_clickable` issue) must not downgrade an active
#        SGR-Pixels (DEC 1016) session — previously it wiped the parser's
#        cached cell size while the terminal kept reporting pixels, and
#        teardown then never sent DECRST 1016 either.
# #16:   `Event::Paste` is routed to the focused widget and up its parent
#        chain until accepted (like a key press), with the window-level emit
#        as the unaccepted fallback; text widgets insert it, and
#        `Widget::Terminal` forwards it to the child (bracketed-paste-wrapped
#        when the child enabled DEC 2004).
# #63:   `Window#send_focus` wires terminal focus-in/out reporting (DEC 1004)
#        through `enable_mouse`, instead of being dead.
#
# Headless harness: a `Window` over in-memory IOs; input is injected as
# constructed `Tput::InputEvent`s via `Window#handle_input`; emitted escape
# sequences are asserted via `Tput#capture`.

private def ppf_screen(width = 60, height = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height, default_quit_keys: false)
end

private def paste_event(text : String)
  Tput::InputEvent.new '\0', paste: text
end

# ── #6/#7: bare enable_mouse must not downgrade SGR-Pixels ───────────────────
describe "BUGS15 6/7: SGR-Pixels survives bare enable_mouse re-asserts" do
  it "keeps the cached cell size across a bare re-assert (sticky request)" do
    s = ppf_screen
    scr = s.screen
    scr.apply_cell_pixels 8, 16
    scr.enable_mouse(pixels: :on)
    scr.tput.mouse_cell_pixels.should eq({8, 16})

    # The listen_mouse / register_clickable path: no pixels argument.
    scr.enable_mouse
    scr.tput.mouse_cell_pixels.should eq({8, 16})
  ensure
    s.try &.destroy
  end

  it "does not emit DECRST 1016 on a bare re-assert of an active pixel session" do
    s = ppf_screen
    scr = s.screen
    scr.apply_cell_pixels 8, 16
    scr.enable_mouse(pixels: :on)
    seq = scr.tput.capture { scr.enable_mouse }
    seq.should_not contain "\e[?1016l"
  ensure
    s.try &.destroy
  end

  it "an explicit :off downgrades in sync: DECRST 1016 and cache cleared" do
    s = ppf_screen
    scr = s.screen
    scr.apply_cell_pixels 8, 16
    scr.enable_mouse(pixels: :on)
    seq = scr.tput.capture { scr.enable_mouse(pixels: :off) }
    seq.should contain "\e[?1016l"
    scr.tput.mouse_cell_pixels.should be_nil
  ensure
    s.try &.destroy
  end

  it "disable_mouse after a pixel session resets 1016 at the terminal" do
    s = ppf_screen
    scr = s.screen
    scr.apply_cell_pixels 8, 16
    scr.enable_mouse(pixels: :on)
    # The formerly-broken sequence: a bare re-assert used to wipe the cache,
    # after which teardown skipped the DECRST and left the terminal in
    # pixel-reporting mode.
    scr.enable_mouse
    seq = scr.tput.capture { scr.disable_mouse }
    seq.should contain "\e[?1016l"
    scr.tput.mouse_cell_pixels.should be_nil
  ensure
    s.try &.destroy
  end

  it "tput: enable_mouse(pixels: nil) preserves, false downgrades only when active" do
    s = ppf_screen
    tput = s.screen.tput
    tput.enable_mouse(pixels: {8, 16})
    tput.enable_mouse
    tput.mouse_cell_pixels.should eq({8, 16})

    # `false` with no active session must not emit a stray DECRST.
    tput.enable_mouse(pixels: false)
    tput.mouse_cell_pixels.should be_nil
    seq = tput.capture(&.enable_mouse(pixels: false))
    seq.should_not contain "\e[?1016l"
  ensure
    s.try &.destroy
  end
end

# ── #63: Window#send_focus wires DEC 1004 ────────────────────────────────────
describe "BUGS15 63: send_focus enables terminal focus reporting (DEC 1004)" do
  it "enable_mouse with send_focus set turns 1004 on" do
    s = ppf_screen
    s.send_focus = true
    seq = s.screen.tput.capture { s.enable_mouse }
    seq.should contain "\e[?1004h"
    s.screen.tput.mouse_focus_enabled?.should be_true
  ensure
    s.try &.destroy
  end

  it "setting send_focus while mouse reporting is live re-asserts immediately" do
    s = ppf_screen
    s.enable_mouse
    s.screen.tput.mouse_focus_enabled?.should be_false
    seq = s.screen.tput.capture { s.send_focus = true }
    seq.should contain "\e[?1004h"
    s.screen.tput.mouse_focus_enabled?.should be_true
  ensure
    s.try &.destroy
  end

  it "a bare device re-assert preserves active focus reporting" do
    s = ppf_screen
    s.send_focus = true
    s.enable_mouse
    seq = s.screen.tput.capture { s.screen.enable_mouse }
    seq.should_not contain "\e[?1004l"
    s.screen.tput.mouse_focus_enabled?.should be_true
  ensure
    s.try &.destroy
  end

  it "send_focus=false turns 1004 back off" do
    s = ppf_screen
    s.send_focus = true
    s.enable_mouse
    seq = s.screen.tput.capture { s.send_focus = false }
    seq.should contain "\e[?1004l"
    s.screen.tput.mouse_focus_enabled?.should be_false
  ensure
    s.try &.destroy
  end

  it "disable_mouse resets 1004 when it was enabled" do
    s = ppf_screen
    s.send_focus = true
    s.enable_mouse
    seq = s.screen.tput.capture { s.screen.disable_mouse }
    seq.should contain "\e[?1004l"
  ensure
    s.try &.destroy
  end
end

# ── #16: Event::Paste routing ────────────────────────────────────────────────
describe "BUGS15 16: Event::Paste routes to the focused widget" do
  it "delivers to the focused widget; an accepted paste skips the window fallback" do
    s = ppf_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
    got = [] of String
    fallback = 0
    box.on(Crysterm::Event::Paste) { |e| got << e.content; e.accept }
    s.on(Crysterm::Event::Paste) { |_| fallback += 1 }
    box.focus
    s.handle_input paste_event("hello")
    got.should eq ["hello"]
    fallback.should eq 0
  ensure
    s.try &.destroy
  end

  it "bubbles up the parent chain until a handler accepts" do
    s = ppf_screen
    outer = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 10
    inner = Widget::Box.new parent: outer, top: 1, left: 1, width: 5, height: 3
    got = [] of String
    outer.on(Crysterm::Event::Paste) { |e| got << e.content; e.accept }
    inner.focus
    s.handle_input paste_event("up")
    got.should eq ["up"]
  ensure
    s.try &.destroy
  end

  it "falls back to the window-level emit when nothing accepts" do
    s = ppf_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
    got = [] of String
    s.on(Crysterm::Event::Paste) { |e| got << e.content }
    box.focus
    s.handle_input paste_event("plain")
    got.should eq ["plain"]
  ensure
    s.try &.destroy
  end

  it "LineEdit inserts pasted text at the cursor" do
    s = ppf_screen
    le = Widget::LineEdit.new parent: s, top: 0, left: 0, width: 40, height: 1
    s.repaint
    le.focus
    s.handle_input paste_event("abc")
    le.value.should eq "abc"
  ensure
    s.try &.destroy
  end

  it "LineEdit flattens pasted newlines (single-line semantics)" do
    s = ppf_screen
    le = Widget::LineEdit.new parent: s, top: 0, left: 0, width: 40, height: 1
    s.repaint
    le.focus
    s.handle_input paste_event("ls -la\n")
    le.value.should eq "ls -la"
    s.handle_input paste_event("a\r\nb")
    le.value.should eq "ls -laa b"
  ensure
    s.try &.destroy
  end

  it "a read-only text widget leaves the paste unaccepted (fallback fires)" do
    s = ppf_screen
    le = Widget::LineEdit.new parent: s, top: 0, left: 0, width: 40, height: 1,
      read_only: true
    fallback = 0
    s.on(Crysterm::Event::Paste) { |_| fallback += 1 }
    s.repaint
    le.focus
    s.handle_input paste_event("nope")
    le.value.should eq ""
    fallback.should eq 1
  ensure
    s.try &.destroy
  end

  it "Terminal forwards a paste to the child raw when 2004 is off in the child" do
    got = [] of String
    s = ppf_screen
    term = Crysterm::Widget::Terminal.new(
      parent: s, top: 0, left: 0, width: 20, height: 5,
      handler: ->(d : String) { got << d; nil })
    s.repaint # bootstrap
    term.focus
    s.handle_input paste_event("echo hi")
    got.should eq ["echo hi"]
  ensure
    s.try &.destroy
  end

  it "Terminal wraps the paste in bracketed-paste markers when the child enabled 2004" do
    got = [] of String
    s = ppf_screen
    term = Crysterm::Widget::Terminal.new(
      parent: s, top: 0, left: 0, width: 20, height: 5,
      handler: ->(d : String) { got << d; nil })
    s.repaint # bootstrap
    term.focus
    term.write "\e[?2004h" # child enables bracketed paste
    s.handle_input paste_event("hi")
    got.should eq ["\e[200~hi\e[201~"]
  ensure
    s.try &.destroy
  end
end
