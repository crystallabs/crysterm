require "./spec_helper"

include Crysterm

# Regressions for BUGS18 B18-41..B18-44 (editors & dialogs):
#
# B18-41: TextEdit's interchange macro generated 1-arg `set_markdown`/`set_html`
#         defs that REPLACED (not overloaded) the earlier themed defaulted-arg
#         defs — the documented `set_markdown(md, theme)` call did not compile,
#         and the surviving 1-arg path imported with `TextTheme.default`
#         instead of the widget's `#theme`.
# B18-42: Bracketed paste (`Event::Paste`) routed through `insert_text`, which
#         never consulted `max_length` — the same text pasted with Ctrl-V was
#         truncated while a terminal paste landed whole.
# B18-43: ComboBox accepted Escape/Backspace/Enter/Up even when the key did
#         nothing (popup closed, empty buffer/options), starving an enclosing
#         Dialog's Enter/Escape accelerator.
# B18-44: `ColorDialog#get_color` (and `Question#ask`/`#ask_choices`,
#         `Prompt#read_input`) showed the "modal" dialog without taking the
#         modal input grab `Dialog#open` takes — widgets beneath stayed
#         clickable.

private def b18ed_window(w = 60, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

private def b18ed_key(k : ::Tput::Key, ch = '\0')
  Crysterm::Event::KeyPress.new ch, k
end

private def b18ed_down(x, y)
  ::Tput::Mouse::Event.new(
    ::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left, x, y, source: :test)
end

# Minimal concrete dialog (the base class is abstract) for accelerator tests.
private class B18edDialog < Crysterm::Widget::Dialog
end

describe "BUGS18 B18-41: TextEdit interchange setters keep the widget theme" do
  it "compiles and honors the explicit 2-arg themed set_markdown" do
    s = b18ed_window
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 8
    explicit = TextTheme.new(code_color: 0x654321)
    te.set_markdown "`c`", explicit
    te.document.char_format_at(1).fg.should eq 0x654321
  end

  it "1-arg set_markdown imports with the widget's #theme, not the default" do
    s = b18ed_window
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 8
    te.theme = TextTheme.new(code_color: 0x123456)
    te.set_markdown "`c`"
    te.document.char_format_at(1).fg.should eq 0x123456
  end

  it "set_html and the =-spellings use the widget's #theme too" do
    s = b18ed_window
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 8
    te.theme = TextTheme.new(link_color: 0xABCDEF)
    te.set_html %(<a href="x">l</a>)
    te.document.char_format_at(1).fg.should eq 0xABCDEF

    te.theme = TextTheme.new(code_color: 0x0F0F0F)
    te.markdown = "`c`"
    te.document.char_format_at(1).fg.should eq 0x0F0F0F

    te.theme = TextTheme.new(link_color: 0x00FF77)
    te.html = %(<a href="y">l</a>)
    te.document.char_format_at(1).fg.should eq 0x00FF77
  end

  it "a wholesale markdown/html replace rewinds the caret" do
    s = b18ed_window
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 8,
      content: "hello"
    te.cursor_position = 5
    te.set_markdown "# hi"
    te.cursor_position.should eq 0

    te.cursor_position = 2
    te.set_html "<p>bye</p>"
    te.cursor_position.should eq 0
  end
end

describe "BUGS18 B18-42: bracketed paste honors max_length" do
  it "caps an Event::Paste to max_length like Ctrl-V does" do
    s = b18ed_window
    le = Widget::LineEdit.new parent: s, top: 0, left: 0, width: 20, height: 1,
      max_length: 8
    le.emit Crysterm::Event::Paste.new("a" * 100)
    le.value.should eq "a" * 8
  end

  it "caps against the room left by existing content" do
    s = b18ed_window
    le = Widget::LineEdit.new parent: s, top: 0, left: 0, width: 20, height: 1,
      max_length: 8
    le.value = "abcd"
    le.emit Crysterm::Event::Paste.new("efghij")
    le.value.should eq "abcdefgh"
  end

  it "pastes in full when no max_length is set" do
    s = b18ed_window
    le = Widget::LineEdit.new parent: s, top: 0, left: 0, width: 20, height: 1
    le.emit Crysterm::Event::Paste.new("hello world")
    le.value.should eq "hello world"
  end

  it "a paste into a full field changes nothing and emits no TextChanged" do
    s = b18ed_window
    le = Widget::LineEdit.new parent: s, top: 0, left: 0, width: 20, height: 1,
      max_length: 4
    le.value = "abcd"
    changes = 0
    le.on(Crysterm::Event::TextChanged) { changes += 1 }
    le.emit Crysterm::Event::Paste.new("zz")
    le.value.should eq "abcd"
    changes.should eq 0
  end
end

describe "BUGS18 B18-43: ComboBox accepts only keys it acts on" do
  it "a closed editable combo lets Escape bubble" do
    s = b18ed_window
    combo = Widget::ComboBox.new %w[one two], parent: s, top: 0, left: 0,
      width: 12, height: 1, editable: true
    e = b18ed_key ::Tput::Key::Escape
    combo.emit e
    e.accepted?.should be_false
  end

  it "an open editable combo still consumes Escape to dismiss" do
    s = b18ed_window
    combo = Widget::ComboBox.new %w[one two], parent: s, top: 0, left: 0,
      width: 12, height: 1, editable: true
    combo.show_popup
    combo.open?.should be_true
    e = b18ed_key ::Tput::Key::Escape
    combo.emit e
    e.accepted?.should be_true
    combo.open?.should be_false
  end

  it "Escape rejects a modal dialog while its closed editable combo is focused" do
    s = b18ed_window
    d = B18edDialog.new parent: s, top: 0, left: 0, width: 30, height: 8
    combo = Widget::ComboBox.new %w[one two], parent: d, top: 1, left: 1,
      width: 12, height: 1, editable: true
    finished = [] of Int32
    d.on(Crysterm::Event::Finished) { |e| finished << e.result }
    d.open
    combo.focus
    s.emit b18ed_key ::Tput::Key::Escape
    finished.should eq [0]
  end

  it "an empty non-editable combo lets Enter and Up bubble" do
    s = b18ed_window
    combo = Widget::ComboBox.new parent: s, top: 0, left: 0, width: 12, height: 1
    e = b18ed_key ::Tput::Key::Enter, '\r'
    combo.emit e
    e.accepted?.should be_false
    combo.open?.should be_false
    e2 = b18ed_key ::Tput::Key::Up
    combo.emit e2
    e2.accepted?.should be_false
  end

  it "a populated non-editable combo still opens on Enter and cycles on Up" do
    s = b18ed_window
    combo = Widget::ComboBox.new %w[a b c], parent: s, top: 0, left: 0,
      width: 12, height: 1
    e = b18ed_key ::Tput::Key::Up
    combo.emit e
    e.accepted?.should be_true
    combo.current_text.should eq "c" # wrapped from index 0

    e2 = b18ed_key ::Tput::Key::Enter, '\r'
    combo.emit e2
    e2.accepted?.should be_true
    combo.open?.should be_true
  end

  it "editable Backspace is consumed only when it erases" do
    s = b18ed_window
    combo = Widget::ComboBox.new %w[one two], parent: s, top: 0, left: 0,
      width: 12, height: 1, editable: true
    e = b18ed_key ::Tput::Key::Backspace
    combo.emit e
    e.accepted?.should be_false # empty filter buffer — nothing erased

    combo.emit Crysterm::Event::KeyPress.new('o') # types into the filter
    e2 = b18ed_key ::Tput::Key::Backspace
    combo.emit e2
    e2.accepted?.should be_true
  end
end

describe "BUGS18 B18-44: block-based dialog presenters take the modal grab" do
  it "get_color grabs the pointer: outside clicks are blocked until close" do
    s = b18ed_window
    btn = Widget::Button.new parent: s, top: 22, left: 0, width: 10, height: 1,
      content: "Outside"
    clicked = 0
    btn.on(Crysterm::Event::Click) { clicked += 1 }
    cd = Widget::ColorDialog.new parent: s, top: 0, left: 0, width: 50, height: 18
    s.repaint

    # Control: with no dialog open the button under (2, 22) takes the click.
    s.dispatch_mouse b18ed_down(2, 22)
    clicked.should eq 1

    cd.get_color { }
    cd.modal?.should be_true
    s.popup_grab_active?.should be_true
    s.repaint
    s.dispatch_mouse b18ed_down(2, 22)
    clicked.should eq 1 # blocked by the modal grab

    cd.reject
    cd.modal?.should be_false
    s.popup_grab_active?.should be_false
    s.repaint
    s.dispatch_mouse b18ed_down(2, 22)
    clicked.should eq 2 # reachable again after close
  end

  it "an eyedropper round-trip does not drop the dialog's modal grab" do
    s = b18ed_window
    cd = Widget::ColorDialog.new parent: s, top: 0, left: 0, width: 50, height: 18
    cd.get_color { }
    s.repaint
    pick = cd.children.find! { |c|
      c.is_a?(Widget::Button) && c.content.includes?("Pick")
    }
    pick.emit Crysterm::Event::Pressed # arms the eyedropper
    s.popup_grab_active?.should be_true

    # The pick click (delivered via the screen-level Event::Mouse) ends the
    # eyedropper; the dialog's own modal grab must survive it.
    s.dispatch_mouse b18ed_down(2, 22)
    cd.modal?.should be_true
    s.popup_grab_active?.should be_true

    cd.reject
    s.popup_grab_active?.should be_false
  end

  it "Question#ask holds the grab until answered" do
    s = b18ed_window
    q = Widget::Question.new parent: s, top: 0, left: 0, width: 40, height: 8
    q.ask("Sure?") { }
    q.modal?.should be_true
    s.popup_grab_active?.should be_true
    s.emit Crysterm::Event::KeyPress.new('y')
    q.modal?.should be_false
    s.popup_grab_active?.should be_false
  end

  it "Question#ask_choices holds the grab until dismissed" do
    s = b18ed_window
    q = Widget::Question.new parent: s, top: 0, left: 0, width: 40, height: 8
    q.ask_choices("Pick one", choices: ["A", "B"]) { }
    q.modal?.should be_true
    s.popup_grab_active?.should be_true
    s.emit b18ed_key ::Tput::Key::Escape
    q.modal?.should be_false
    s.popup_grab_active?.should be_false
  end

  it "Prompt#read_input takes the grab and #done releases it" do
    s = b18ed_window
    p = Widget::Prompt.new parent: s, content: "Name?"
    p.read_input { }
    p.modal?.should be_true
    s.popup_grab_active?.should be_true
    p.reject
    p.modal?.should be_false
    s.popup_grab_active?.should be_false
  end
end
