require "./spec_helper"

# `Neovim::Handler` against a real `nvim`: vi editing on the three
# `Mixin::TextEditing` widgets. Keys go through the widget's `KeyPress` as a
# window delivers them; each waits until the widget mirrors what Neovim did.

private def nvh_window
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: 24, default_quit_keys: false)
end

# Types *text* into *w* one key at a time, `<…>` naming a special key as
# Neovim's notation does (`<Esc>`, `<CR>`, `<C-r>`).
private def nvh_type(w, text : String)
  text.scan(/<[^>]+>|./m) do |m|
    s = m[0]
    e =
      case s
      when "<Esc>" then Crysterm::Event::KeyPress.new('\e', Tput::Key::Escape)
      when "<CR>"  then Crysterm::Event::KeyPress.new('\r', Tput::Key::Enter)
      when "<C-r>" then Crysterm::Event::KeyPress.new('\u0012', Tput::Key::CtrlR)
      when "<C-v>" then Crysterm::Event::KeyPress.new('\u0016', Tput::Key::CtrlV)
      when "<F5>"  then Crysterm::Event::KeyPress.new('\0', Tput::Key::F5)
      when "<M-x>" then Crysterm::Event::KeyPress.new('x', Tput::Key::AltX)
      else              Crysterm::Event::KeyPress.new(s[0], nil)
      end
    w.emit e
  end
end

private def with_handler(w, &)
  h = Crysterm::Neovim::Handler.new
  h.attach(w).should be_true
  begin
    yield h
  ensure
    h.detach
  end
end

describe Crysterm::Neovim::Handler do
  unless Crysterm::Neovim.available?
    pending "needs nvim in PATH"
    next
  end

  it "edits a PlainTextEdit: dd, x, ciw, insert, u" do
    s = nvh_window
    w = Crysterm::Widget::PlainTextEdit.new parent: s, width: 40, height: 10
    w.value = "one two\nsecond line\nthird"
    with_handler(w) do |h|
      h.mode.should eq Crysterm::Neovim::Mode::Normal
      nvh_type w, "gg0"
      w.cursor_pos.should eq 0
      nvh_type w, "jdd"
      w.value.should eq "one two\nthird"
      nvh_type w, "ggx"
      w.value.should eq "ne two\nthird"
      nvh_type w, "wciwTWO<Esc>"
      w.value.should eq "ne TWO\nthird"
      h.mode.should eq Crysterm::Neovim::Mode::Normal
      nvh_type w, "Ahello"
      h.mode.should eq Crysterm::Neovim::Mode::Insert
      w.value.should eq "ne TWOhello\nthird"
      w.cursor_pos.should eq 11
      nvh_type w, "<Esc>u"
      w.value.should eq "ne TWO\nthird"
      nvh_type w, "<C-r>"
      w.value.should eq "ne TWOhello\nthird"
      nvh_type w, "uuuu"
      w.value.should eq "one two\nsecond line\nthird"
    end
  end

  it "edits a TextEdit, the formats outside the change kept" do
    s = nvh_window
    w = Crysterm::Widget::TextEdit.new parent: s, width: 40, height: 10
    w.set_markdown "**bold** plain"
    with_handler(w) do |_|
      w.value.should eq "bold plain"
      nvh_type w, "$x"
      w.value.should eq "bold plai"
      w.document.typing_format_at(2).bold?.should be_true
      nvh_type w, "0lx"
      w.value.should eq "bld plai"
      w.document.typing_format_at(1).bold?.should be_true
      w.document.typing_format_at(2).bold?.should be_true
    end
  end

  it "moves Neovim's cursor where the widget is clicked" do
    s = nvh_window
    w = Crysterm::Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 40, height: 10
    w.value = "first line\nsecond line"
    s.repaint
    with_handler(w) do |h|
      click s, 3, 1
      w.cursor_pos.should eq 14
      h.sync
      nvh_type w, "x"
      w.value.should eq "first line\nsecnd line"
      w.cursor_pos.should eq 14
    end
  end

  it "gives each widget on a shared Neovim a buffer of its own" do
    s = nvh_window
    a = Crysterm::Widget::PlainTextEdit.new parent: s, width: 40, height: 5
    b = Crysterm::Widget::LineEdit.new parent: s, top: 6, width: 40, height: 1, content: "line"
    a.value = "first\nsecond"
    client = Crysterm::Neovim::Client.new args: Crysterm::Neovim::Handler.default_args
    begin
      ha = Crysterm::Neovim::Handler.new client
      hb = Crysterm::Neovim::Handler.new client
      ha.attach(a).should be_true
      hb.attach(b).should be_true
      nvh_type a, "ggdd"
      a.value.should eq "second"
      nvh_type b, "0x"
      b.value.should eq "ine"
      nvh_type a, "u"
      a.value.should eq "first\nsecond"
      b.value.should eq "ine"
      hb.detach
      client.running?.should be_true
      nvh_type a, "G0x"
      a.value.should eq "first\necond"
      ha.detach
    ensure
      client.close
    end
  end

  it "records Neovim's edits on the widget's undo stack" do
    s = nvh_window
    w = Crysterm::Widget::PlainTextEdit.new parent: s, width: 40, height: 10
    w.value = "abc"
    with_handler(w) do |h|
      nvh_type w, "0x"
      w.value.should eq "bc"
      w.undo.should be_true
      w.value.should eq "abc"
      # The widget's undo reaches Neovim as an outside change.
      h.sync
      nvh_type w, "$x"
      w.value.should eq "ab"
    end
  end

  it "mirrors the cursor over multibyte text" do
    s = nvh_window
    w = Crysterm::Widget::PlainTextEdit.new parent: s, width: 40, height: 10
    w.value = "žžž abc\nčć x"
    with_handler(w) do |_|
      nvh_type w, "gg"
      nvh_type w, "w"
      w.cursor_pos.should eq 4
      nvh_type w, "j0l"
      w.cursor_pos.should eq 9
      nvh_type w, "x"
      w.value.should eq "žžž abc\nč x"
    end
  end

  it "shows Visual mode as the widget's selection" do
    s = nvh_window
    w = Crysterm::Widget::PlainTextEdit.new parent: s, width: 40, height: 10
    w.value = "hello world\nsecond"
    with_handler(w) do |h|
      nvh_type w, "ggwve"
      h.mode.should eq Crysterm::Neovim::Mode::Visual
      w.selected_text.should eq "world"
      nvh_type w, "<Esc>ggV"
      h.mode.should eq Crysterm::Neovim::Mode::VisualLine
      nvh_type w, "j"
      w.selected_text.should eq "hello world\nsecond"
      nvh_type w, "<Esc>"
      w.selection?.should be_false
    end
  end

  it "sends an edit made outside Neovim to it, and a caret move" do
    s = nvh_window
    w = Crysterm::Widget::PlainTextEdit.new parent: s, width: 40, height: 10
    w.value = "first\nsecond"
    with_handler(w) do |h|
      w.cursor_pos = 6
      w.insert_text "new "
      w.value.should eq "first\nnew second"
      h.sync
      nvh_type w, "0dw"
      w.value.should eq "first\nsecond"
      w.value = "replaced text"
      h.sync
      nvh_type w, "0x"
      w.value.should eq "eplaced text"
      # Neovim's undo takes back the outside change too.
      nvh_type w, "uu"
      w.value.should eq "first\nsecond"
    end
  end

  it "keeps a LineEdit on one line, and lets Enter and Escape reach it" do
    s = nvh_window
    w = Crysterm::Widget::LineEdit.new parent: s, width: 40, height: 1, content: "abc"
    submitted = nil
    cancelled = false
    w.on(Crysterm::Event::Submitted) { |e| submitted = e.value }
    w.on(Crysterm::Event::Cancelled) { cancelled = true }
    w.focus
    w.read_input
    with_handler(w) do |h|
      nvh_type w, "0x"
      w.value.should eq "bc"
      nvh_type w, "odef<Esc>"
      w.value.should eq "bc def"
      w.value.includes?('\n').should be_false
      nvh_type w, "<CR>"
      submitted.should eq "bc def"
      w.read_input
      nvh_type w, "A!<Esc>"
      w.value.should eq "bc def!"
      h.mode.should eq Crysterm::Neovim::Mode::Normal
      nvh_type w, "<Esc>"
      cancelled.should be_true
    end
  end

  it "pastes through Neovim, once" do
    s = nvh_window
    w = Crysterm::Widget::PlainTextEdit.new parent: s, width: 40, height: 10
    w.value = "abc"
    w.focus
    w.read_input
    with_handler(w) do |h|
      nvh_type w, "0"
      w.emit Crysterm::Event::Paste.new("XY")
      w.value.size.should eq 5
      w.value.scan("XY").size.should eq 1
      nvh_type w, "u"
      w.value.should eq "abc"
      h.mode.should eq Crysterm::Neovim::Mode::Normal
    end
  end

  it "lets the pass-through keys go on to the widget and the window" do
    s = nvh_window
    w = Crysterm::Widget::PlainTextEdit.new parent: s, width: 40, height: 10
    w.value = "abc"
    seen = [] of Tput::Key?
    w.on(Crysterm::Event::KeyPress) { |e| seen << e.key }
    with_handler(w) do |h|
      nvh_type w, "<F5><M-x>x"
      seen.should eq [Tput::Key::F5, Tput::Key::AltX, nil]
      w.value.should eq "ab"
      h.pass_through = ->(e : Crysterm::Event::KeyPress) { e.char == 'x' }
      nvh_type w, "0x"
      w.value.should eq "ab"
      w.cursor_pos.should eq 0
    end
  end

  it "reports the command line and messages, and asks to write and quit" do
    s = nvh_window
    w = Crysterm::Widget::PlainTextEdit.new parent: s, width: 40, height: 10
    w.value = "text"
    with_handler(w) do |h|
      lines = [] of String?
      writes = [] of String?
      quits = [] of {Bool, Bool}
      h.on(Crysterm::Event::ViCommandLineChanged) { |e| lines << e.text }
      h.on(Crysterm::Event::ViWriteRequested) { |e| writes << e.path }
      h.on(Crysterm::Event::ViQuitRequested) { |e| quits << {e.bang, e.all} }
      nvh_type w, ":ec"
      h.mode.should eq Crysterm::Neovim::Mode::CommandLine
      wait_until { h.command_line == ":ec" }
      nvh_type w, "ho 'hi'<CR>"
      wait_until { h.message == "hi" }
      h.command_line.should be_nil
      lines.should contain ":ec"
      nvh_type w, ":w<CR>"
      wait_until { writes.size == 1 }
      writes.should eq [nil]
      nvh_type w, ":q!<CR>"
      wait_until { quits.size == 1 }
      quits.should eq [{true, false}]
      nvh_type w, ":wq<CR>"
      wait_until { quits.size == 2 }
      writes.size.should eq 2
      h.attached?.should be_true
      nvh_type w, "0x"
      w.value.should eq "ext"
    end
  end

  it "detaches, giving the widget its keys back" do
    s = nvh_window
    w = Crysterm::Widget::PlainTextEdit.new parent: s, width: 40, height: 10
    w.value = "abc"
    w.focus
    w.read_input
    h = Crysterm::Neovim::Handler.new
    h.attach(w).should be_true
    client = h.client.not_nil!
    nvh_type w, "0x"
    w.value.should eq "bc"
    h.detach
    h.attached?.should be_false
    client.running?.should be_false
    nvh_type w, "x"
    w.value.should eq "xbc"
  end

  it "detaches when Neovim exits, and fails to attach without Neovim" do
    s = nvh_window
    w = Crysterm::Widget::PlainTextEdit.new parent: s, width: 40, height: 10
    w.value = "abc"
    h = Crysterm::Neovim::Handler.new
    h.attach(w).should be_true
    exited = false
    h.on(Crysterm::Event::ProcessExited) { exited = true }
    h.client.not_nil!.notify "nvim_command", "qall!"
    wait_until { exited }
    h.attached?.should be_false

    missing = Crysterm::Neovim::Handler.new executable: "no-such-nvim-here"
    missing.attach(w).should be_false
    missing.attached?.should be_false
  end
end
