require "./spec_helper"

include Crysterm

# Regression specs for BUGS15 findings #82 and #89 (Widget::Terminal I/O).
#
# #82: keystrokes arriving via an enhanced keyboard protocol (kitty CSI-u /
#      modifyOtherKeys) must be re-encoded to legacy bytes before being
#      forwarded to the child — the child never negotiated the protocol, so
#      forwarding the raw enhanced sequence (`\e[99;5u` for Ctrl+C) means no
#      SIGINT and junk input.
# #89: bytes `#write`-n before the first render (emulator not yet
#      bootstrapped) must be buffered and replayed, not silently dropped.
#
# Headless harness: a `Window` over in-memory IOs, a handler-mode terminal
# (no PTY), rendering driven synchronously with `repaint`.

private def tio_screen(width = 60, height = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height, default_quit_keys: false)
end

private def em_row_text(em, row, len)
  String.build do |io|
    len.times { |x| io << (em.lines[row]?.try(&.[x]?).try(&.char) || ' ') }
  end
end

# A focused handler-mode terminal whose child-bound bytes are captured into
# *got*. Yields {window, terminal}.
private def tio_terminal(got : Array(String), width = 20, height = 5)
  s = tio_screen
  term = Crysterm::Widget::Terminal.new(
    parent: s, top: 0, left: 0, width: width, height: height,
    handler: ->(d : String) { got << d; nil })
  s.repaint # bootstrap
  term.focus
  {s, term}
end

# An `Event::KeyPress` as `Window#handle_input` would build it for an
# enhanced-protocol keystroke: `sequence` keeps the RAW enhanced bytes,
# `key_event` carries the parsed event.
private def enhanced_press(raw : String, ke : Tput::KeyEvent)
  Crysterm::Event::KeyPress.new(ke.char || '\u{0}', ke.to_legacy_key, raw.chars, ke)
end

# ── #82: enhanced-protocol keystrokes are re-encoded to legacy bytes ─────────
describe "BUGS15 82: Widget::Terminal re-encodes enhanced key sequences for the child" do
  it "forwards Ctrl+C as 0x03, not the raw kitty CSI-u sequence" do
    got = [] of String
    s, term = tio_terminal got
    term.emit enhanced_press("\e[99;5u", Tput::KeyEvent.new(99, 'u', Tput::Modifiers::Ctrl))
    got.should eq ["\u{3}"]
  ensure
    s.try &.destroy
  end

  it "forwards Esc as \\e, not \\e[27u" do
    got = [] of String
    s, term = tio_terminal got
    term.emit enhanced_press("\e[27u", Tput::KeyEvent.new(27, 'u'))
    got.should eq ["\e"]
  ensure
    s.try &.destroy
  end

  it "forwards Alt+x as ESC-prefixed x" do
    got = [] of String
    s, term = tio_terminal got
    term.emit enhanced_press("\e[120;3u", Tput::KeyEvent.new(120, 'u', Tput::Modifiers::Alt))
    got.should eq ["\ex"]
  ensure
    s.try &.destroy
  end

  it "forwards a plain enhanced 'a' (kitty report-all-keys) as the character" do
    got = [] of String
    s, term = tio_terminal got
    term.emit enhanced_press("\e[97u", Tput::KeyEvent.new(97, 'u'))
    got.should eq ["a"]
  ensure
    s.try &.destroy
  end

  it "forwards nothing for a lone modifier press" do
    got = [] of String
    s, term = tio_terminal got
    term.emit enhanced_press("\e[57441u", Tput::KeyEvent.new(57441, 'u'))
    got.should be_empty
  ensure
    s.try &.destroy
  end

  it "passes legacy-mode input through untouched" do
    got = [] of String
    s, term = tio_terminal got
    term.emit Crysterm::Event::KeyPress.new('a')
    term.emit Crysterm::Event::KeyPress.new('\e', Tput::Key::Up, "\e[A".chars)
    got.should eq ["a", "\e[A"]
  ensure
    s.try &.destroy
  end

  it "keeps enhanced Shift-PageUp/PageDown as scrollback keys, not forwarded input" do
    got = [] of String
    s, term = tio_terminal got
    scrolls = 0
    term.on(Crysterm::Event::Scroll) { scrolls += 1 }
    # Kitty events-mode Shift-PageUp: `~` final with a Shift modifier; its
    # legacy re-encoding is exactly the `\e[5;2~` the scrollback match expects.
    term.emit enhanced_press("\e[5;2:1~", Tput::KeyEvent.new(5, '~', Tput::Modifiers::Shift))
    term.emit enhanced_press("\e[6;2:1~", Tput::KeyEvent.new(6, '~', Tput::Modifiers::Shift))
    got.should be_empty
    scrolls.should eq 2
  ensure
    s.try &.destroy
  end
end

# ── #82: KeyEvent#to_legacy_bytes mapping table ──────────────────────────────
describe "Tput::KeyEvent#to_legacy_bytes" do
  it "maps C0-coded keys and ctrl/alt chords" do
    Tput::KeyEvent.new(27, 'u').to_legacy_bytes.should eq "\e"
    Tput::KeyEvent.new(13, 'u').to_legacy_bytes.should eq "\r"
    Tput::KeyEvent.new(13, 'u', Tput::Modifiers::Alt).to_legacy_bytes.should eq "\e\r"
    Tput::KeyEvent.new(9, 'u').to_legacy_bytes.should eq "\t"
    Tput::KeyEvent.new(9, 'u', Tput::Modifiers::Shift).to_legacy_bytes.should eq "\e[Z"
    Tput::KeyEvent.new(127, 'u').to_legacy_bytes.should eq "\u{7f}"
    Tput::KeyEvent.new(127, 'u', Tput::Modifiers::Ctrl).to_legacy_bytes.should eq "\b"
    Tput::KeyEvent.new(99, 'u', Tput::Modifiers::Ctrl).to_legacy_bytes.should eq "\u{3}"
    # Ctrl+Shift+C still reaches the child as 0x03 (legacy terminals do not
    # distinguish), Ctrl+Alt+C as ESC + 0x03.
    Tput::KeyEvent.new(99, 'u', Tput::Modifiers::Ctrl | Tput::Modifiers::Shift).to_legacy_bytes.should eq "\u{3}"
    Tput::KeyEvent.new(99, 'u', Tput::Modifiers::Ctrl | Tput::Modifiers::Alt).to_legacy_bytes.should eq "\e\u{3}"
    Tput::KeyEvent.new(' '.ord, 'u', Tput::Modifiers::Ctrl).to_legacy_bytes.should eq "\u{0}"
    Tput::KeyEvent.new('['.ord, 'u', Tput::Modifiers::Ctrl).to_legacy_bytes.should eq "\e"
    # Ctrl+<no control form> degrades to the plain character, like xterm.
    Tput::KeyEvent.new('1'.ord, 'u', Tput::Modifiers::Ctrl).to_legacy_bytes.should eq "1"
    # The ambient lock bits are ignored.
    Tput::KeyEvent.new(99, 'u', Tput::Modifiers::Ctrl | Tput::Modifiers::NumLock).to_legacy_bytes.should eq "\u{3}"
  end

  it "maps text keys through shift/alt and associated text" do
    Tput::KeyEvent.new(97, 'u').to_legacy_bytes.should eq "a"
    Tput::KeyEvent.new(120, 'u', Tput::Modifiers::Alt).to_legacy_bytes.should eq "\ex"
    Tput::KeyEvent.new(97, 'u', Tput::Modifiers::Shift, shifted: 65).to_legacy_bytes.should eq "A"
    # Terminal-supplied associated text wins (layouts, caps lock, dead keys).
    Tput::KeyEvent.new(97, 'u', text: "á").to_legacy_bytes.should eq "á"
  end

  it "maps navigation and function keys to their legacy CSI/SS3 forms" do
    Tput::KeyEvent.new(1, 'A').to_legacy_bytes.should eq "\e[A"
    Tput::KeyEvent.new(1, 'A', Tput::Modifiers::Ctrl).to_legacy_bytes.should eq "\e[1;5A"
    Tput::KeyEvent.new(1, 'H', Tput::Modifiers::Shift).to_legacy_bytes.should eq "\e[1;2H"
    Tput::KeyEvent.new(5, '~', Tput::Modifiers::Shift).to_legacy_bytes.should eq "\e[5;2~"
    Tput::KeyEvent.new(3, '~').to_legacy_bytes.should eq "\e[3~"
    Tput::KeyEvent.new(15, '~').to_legacy_bytes.should eq "\e[15~"
    Tput::KeyEvent.new(1, 'P').to_legacy_bytes.should eq "\eOP"
    Tput::KeyEvent.new(1, 'Q', Tput::Modifiers::Shift).to_legacy_bytes.should eq "\e[1;2Q"
  end

  it "returns nil for releases, lone modifiers and unencodable functional keys" do
    Tput::KeyEvent.new(99, 'u', Tput::Modifiers::Ctrl, Tput::KeyEvent::Type::Release).to_legacy_bytes.should be_nil
    Tput::KeyEvent.new(57441, 'u').to_legacy_bytes.should be_nil # left Shift
    Tput::KeyEvent.new(57428, 'u').to_legacy_bytes.should be_nil # kitty PUA functional
  end

  it "re-encodes a modifyOtherKeys format-0 Ctrl+C parsed via from_csi" do
    # `\e[27;5;99~` — xterm modifyOtherKeys format 0.
    ke = Tput::KeyEvent.from_csi('~', 27, nil, nil, 5, nil, [99] of Int32?)
    ke.to_legacy_bytes.should eq "\u{3}"
  end
end

# ── #89: pre-bootstrap writes are buffered, not dropped ──────────────────────
describe "BUGS15 89: Widget::Terminal#write before the first render" do
  it "replays bytes written before bootstrap into the emulator, in order" do
    s = tio_screen
    term = Crysterm::Widget::Terminal.new(
      parent: s, top: 0, left: 0, width: 20, height: 5,
      handler: ->(_d : String) { })
    term.emulator.should be_nil
    term.write "hel"
    term.write "lo".to_slice
    s.repaint # bootstrap: pending bytes must be replayed
    em = term.emulator.not_nil!
    em_row_text(em, 0, 5).should eq "hello"
    # And they reach the screen cells on that same first render.
    lp = term.lpos.not_nil!
    String.build { |io| 5.times { |x| io << s.lines[lp.yi][lp.xi + x].char } }.should eq "hello"
  ensure
    s.try &.destroy
  end

  it "routes solicited replies from replayed bytes to the handler" do
    got = [] of String
    s = tio_screen
    term = Crysterm::Widget::Terminal.new(
      parent: s, top: 0, left: 0, width: 20, height: 5,
      handler: ->(d : String) { got << d; nil })
    # A DSR cursor-position probe written before bootstrap: the reply can only
    # be produced if the pending buffer is fed AFTER em.output is wired.
    term.write "\e[6n"
    got.should be_empty
    s.repaint
    got.join.should eq "\e[1;1R"
  ensure
    s.try &.destroy
  end

  it "still feeds the emulator directly once bootstrapped" do
    s = tio_screen
    term = Crysterm::Widget::Terminal.new(
      parent: s, top: 0, left: 0, width: 20, height: 5,
      handler: ->(_d : String) { })
    s.repaint
    term.write "later"
    em = term.emulator.not_nil!
    em_row_text(em, 0, 5).should eq "later"
  ensure
    s.try &.destroy
  end
end
