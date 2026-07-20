require "./spec_helper"

include Crysterm

# Regression coverage for a batch of BUGS-F2 findings owned by this agent:
#
#  13 (widget_media_*.cr)   overlay/graphics media backends crashed at
#                           construction when built detached (no window yet).
#  18 (window_cursor.cr)    `reset_cursor` aliased `cursor_color` (the most
#                           recently defined method) instead of `cursor_reset`,
#                           so it recolored the cursor rather than resetting it.
#  19 (action.cr)           a plain character between the two strokes of a chord
#                           didn't clear the pending prefix, so the chord could
#                           complete spuriously.
#  24 (window.cr)           `Window#screen=` emitted `ScreenAdded` unconditionally
#                           and stranded the old device's terminal.
#  46 (widget_terminal_emulator.cr) CSI intermediate bytes were swallowed but
#                           ignored at dispatch, so e.g. `$ r` ran as DECSTBM.
#  47 (widget_terminal_emulator.cr) discarded DCS/SOS/PM/APC payloads were still
#                           appended to the OSC buffer, retaining capacity.

private def f2_window(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: w, height: h,
    default_quit_keys: false)
end

private DFL2 = Crysterm::Attr.pack(0, Crysterm::Attr::COLOR_DEFAULT, Crysterm::Attr::COLOR_DEFAULT)

private def f2_emu(cols = 12, rows = 6)
  Crysterm::TerminalEmulator.new(cols, rows, DFL2)
end

private def f2_row(em, y)
  em.lines[em.ydisp + y].map(&.char).join.delete('\u0000').rstrip
end

private def f2_shared_device
  Crysterm::Screen.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 40, height: 10)
end

# ─────────────────────────── Finding 18 ───────────────────────────
describe "BUGS-F2 finding 18: Window#reset_cursor resets shape/blink" do
  it "restores shape==Block and blink==false (was aliased to cursor_color)" do
    s = f2_window

    s.set_cursor_shape Tput::CursorShape::Underline, blink: true
    s.cursor.shape.underline?.should be_true
    s.cursor.blink.should be_true

    # Before the fix `reset_cursor` was an alias of `cursor_color`, so this left
    # the shape/blink untouched (and cleared the color). It must now reset them.
    s.reset_cursor
    s.cursor.shape.block?.should be_true
    s.cursor.blink.should be_false
  end
end

# ─────────────────────────── Finding 19 ───────────────────────────
describe "BUGS-F2 finding 19: a plain character clears a pending chord prefix" do
  it "does not complete a chord when ordinary text is typed between its strokes" do
    s = f2_window
    tb = Crysterm::Widget::ToolBar.new parent: s, top: 0, left: 0, width: "100%", height: 1
    a = Action.new "Bold", shortcuts: [[Tput::Key::CtrlK, Tput::Key::CtrlB]]
    fired = 0
    a.on(Event::Triggered) { fired += 1 }
    tb.add_action a

    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlK) # start chord
    # A printable character is delivered with key==nil — it must clear the prefix.
    s.emit Crysterm::Event::KeyPress.new('x')
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlB) # lone CtrlB now
    fired.should eq 0                                            # chord must NOT have completed spuriously

    # The full sequence still works afterwards.
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlK)
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlB)
    fired.should eq 1
  end
end

# ─────────────────────────── Finding 46 ───────────────────────────
describe "BUGS-F2 finding 46: CSI intermediate bytes are not dispatched as the bare final" do
  it "ignores `CSI Pt;Pb $ r` (DECCARA) instead of running it as DECSTBM `r`" do
    em = f2_emu(12, 6)

    # Park the cursor away from home so DECSTBM's cursor-homing is observable.
    em.feed "\e[3;1H"
    em.cursor_y.should eq 2

    # `$` (0x24) is an intermediate byte: this is DECCARA, not DECSTBM. It must
    # NOT set the scroll region / home the cursor.
    em.feed "\e[1;4$r"
    em.cursor_y.should eq 2

    # Sanity: the *plain* form (no intermediate) is DECSTBM and does home the cursor.
    em.feed "\e[1;4r"
    em.cursor_y.should eq 0
  end

  it "ignores `CSI Ps SP @` (SL) instead of running it as ICH `@`" do
    em = f2_emu(12, 6)
    em.feed "abcd"
    em.feed "\e[H" # cursor home (col 0)

    # SP (0x20) intermediate: this is SL (scroll left), not ICH — no blanks inserted.
    em.feed "\e[2 @"
    f2_row(em, 0).should eq "abcd"

    # Sanity: plain ICH inserts 2 blanks at the cursor.
    em.feed "\e[2@"
    f2_row(em, 0).should eq "  abcd"
  end
end

# ─────────────────────────── Finding 47 ───────────────────────────
describe "BUGS-F2 finding 47: discarded DCS/SOS/PM/APC payloads are not buffered" do
  it "does not accumulate a DCS payload into the OSC buffer" do
    em = f2_emu

    # A DCS string (ESC P … ST) with a long payload; its bytes must be swallowed
    # to find the terminator but NOT appended to @osc_buf (which would retain
    # capacity for the widget's lifetime).
    em.feed "\eP" + ("q" * 500) + "\e\\"
    em.osc_buffer_size.should eq 0

    # Sanity: a real OSC title *does* buffer its payload (and still parses).
    got = [] of String
    em.on_title = ->(t : String) { got << t; nil }
    em.feed "\e]0;hello\a"
    got.should eq ["hello"]
  end

  it "never parses a DCS payload as a window title" do
    em = f2_emu
    got = [] of String
    em.on_title = ->(t : String) { got << t; nil }
    # Looks like an OSC 0 title, but arriving via DCS it must be discarded.
    em.feed "\eP0;PWNED\e\\"
    got.empty?.should be_true
  end
end

# ─────────────────────────── Finding 24 ───────────────────────────
describe "BUGS-F2 finding 24: Window#screen= gates ScreenAdded and tears down the old device" do
  it "does not double-emit ScreenAdded when moving onto a device a sibling uses, and restores the stranded old device" do
    app = Crysterm::Application.new
    dev_a = f2_shared_device
    dev_b = f2_shared_device
    w1 = Crysterm::Window.new(screen: dev_a, default_quit_keys: false)
    w2 = Crysterm::Window.new(screen: dev_b, default_quit_keys: false)
    app.add w1
    app.add w2
    dev_a.tput.is_alt.should be_true

    added = [] of Crysterm::Screen
    app.on(Crysterm::Event::ScreenAdded) { |e| added << e.screen }

    # Move w1 onto dev_b, which w2 already backs.
    w1.screen = dev_b

    added.should be_empty             # no duplicate ScreenAdded for dev_b
    dev_a.tput.is_alt.should be_false # dev_a's last window left -> terminal restored
  end

  it "emits ScreenAdded when moved onto a genuinely new device, keeping a still-shared old device" do
    app = Crysterm::Application.new
    dev_a = f2_shared_device
    dev_b = f2_shared_device
    w1 = Crysterm::Window.new(screen: dev_a, default_quit_keys: false)
    w2 = Crysterm::Window.new(screen: dev_a, default_quit_keys: false)
    app.add w1
    app.add w2

    added = [] of Crysterm::Screen
    app.on(Crysterm::Event::ScreenAdded) { |e| added << e.screen }

    w1.screen = dev_b # brand-new device

    added.should eq [dev_b]
    dev_a.tput.is_alt.should be_true # dev_a still used by w2 -> not torn down
  end
end

# ─────────────────────────── Finding 13 ───────────────────────────
describe "BUGS-F2 finding 13: overlay media backends construct detached without raising" do
  it "constructs an in-band graphics backend (Sixel) detached, then attaches" do
    sixel = Crysterm::Widget::Media::Sixel.new file: "does-not-exist.png"
    s = f2_window
    s << sixel
    s.repaint # exercises the deferred Rendered listener + cell-pixel re-resolve

    # After attach the real cell size is adopted (was stuck at the 10x20 fallback).
    if s.cell_pixel_width > 0
      sixel.cell_pixel_width.should eq s.cell_pixel_width
    end
    if s.cell_pixel_height > 0
      sixel.cell_pixel_height.should eq s.cell_pixel_height
    end
  end

  it "constructs a graphics backend under a detached parent, then attaches the subtree" do
    box = Crysterm::Widget::Box.new
    Crysterm::Widget::Media::Sixel.new file: "does-not-exist.png", parent: box
    s = f2_window
    s << box
    s.repaint
  end

  it "constructs the RenderHook backends (Tek/Ueberzug) detached, then attaches" do
    tek = Crysterm::Widget::Media::Tek.new file: "does-not-exist.png"
    uz = Crysterm::Widget::Media::Ueberzug.new file: "does-not-exist.png"
    s = f2_window
    s << tek
    s << uz
    s.repaint
  end

  it "constructs the external Overlay (w3m) backend detached, then attaches" do
    ov = Crysterm::Widget::Media::Overlay.new file: "does-not-exist.png"
    s = f2_window
    s << ov
    s.repaint
  end
end
