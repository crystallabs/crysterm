require "./spec_helper"

include Crysterm

# `TextEdit#links_enabled?` (the plain-boolean stand-in for Qt's
# `Qt::LinksAccessibleByMouse`/`ByKeyboard`) and `TextBrowser#link_clicks`:
# off, anchors paint as the surrounding text, emit no OSC 8 and neither the
# keys nor the mouse follow them; `link_clicks = 2` wants a double click.

private def ctl(k : ::Tput::Key)
  Crysterm::Event::KeyPress.new '\0', k
end

private def linked_tb(s)
  tb = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: 40, height: 8
  tb.document = TextDocument.from_markdown("go [one](u://1) and [two](u://2)")
  s.repaint
  tb
end

private def click(s, x, y)
  s.dispatch_mouse ::Tput::Mouse::Event.new(
    ::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left, x, y, source: :test)
end

private def osc8_window(output : IO::Memory)
  s = Crysterm::Window.new(
    input: IO::Memory.new, output: output, error: IO::Memory.new,
    width: 40, height: 8)
  s.hyperlinks = Crysterm::AutoToggle::On
  s
end

describe "TextEdit#links_enabled?" do
  it "is on by default and paints a link in the palette link color, underlined" do
    s = headless_screen(40, 8)
    tb = linked_tb s
    tb.links_enabled?.should be_true
    # "go one" — 'o' of "one" at column 3, 'g' of "go" at column 0.
    link = s.cell_rows[0][3].attr
    plain = s.cell_rows[0][0].attr
    Attr.unpack_color(Attr.fg(link)).should eq tb.palette.link.not_nil!
    (Attr.flags(link) & Attr::UNDERLINE).should_not eq 0
    link.should_not eq plain
  end

  it "paints a link as plain text when off, and relights it when back on" do
    s = headless_screen(40, 8)
    tb = linked_tb s
    tb.links_enabled = false
    s.repaint
    s.cell_rows[0][3].attr.should eq s.cell_rows[0][0].attr
    (Attr.flags(s.cell_rows[0][3].attr) & Attr::UNDERLINE).should eq 0
    # The document keeps its anchors.
    tb.links.size.should eq 2
    tb.links_enabled = true
    s.repaint
    s.cell_rows[0][3].attr.should_not eq s.cell_rows[0][0].attr
  end

  it "keeps an underline the format carries on its own" do
    s = headless_screen(40, 8)
    tb = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: 40, height: 8, content: "click here"
    tb.document.cursor(0, 5).set_char_format(TextCharFormat.new(anchor_href: "u://x", underline: true))
    tb.links_enabled = false
    s.repaint
    (Attr.flags(s.cell_rows[0][0].attr) & Attr::UNDERLINE).should_not eq 0
  end

  it "emits OSC 8 for a link when on and none when off" do
    outp = IO::Memory.new
    s = osc8_window outp
    linked_tb s
    outp.to_s.should contain "\e]8;;u://1\e\\"

    outp2 = IO::Memory.new
    s2 = osc8_window outp2
    tb = Widget::TextBrowser.new parent: s2, left: 0, top: 0, width: 40, height: 8
    tb.links_enabled = false
    tb.document = TextDocument.from_markdown("go [one](u://1) and [two](u://2)")
    s2.repaint
    outp2.to_s.should_not contain "\e]8;"
    s2.cell_rows[0][3].link.should eq 0
  end

  it "does not cycle links with Tab nor follow with Enter when off" do
    s = headless_screen(40, 8)
    tb = linked_tb s
    clicked = [] of String
    tb.on(Crysterm::Event::AnchorClick) { |e| clicked << e.url }
    tb.links_enabled = false
    tb._listener ctl(::Tput::Key::Tab)
    tb.focused_link.should eq -1
    tb._listener ctl(::Tput::Key::ShiftTab)
    tb.focused_link.should eq -1
    tb._listener ctl(::Tput::Key::Enter)
    clicked.should be_empty
  end

  it "drops keyboard link focus when switched off" do
    s = headless_screen(40, 8)
    tb = linked_tb s
    tb.focus_link(1).should be_true
    tb.focused_link.should eq 0
    tb.extra_selections.size.should eq 1
    clicked = [] of String
    tb.on(Crysterm::Event::AnchorClick) { |e| clicked << e.url }
    tb.links_enabled = false
    tb.focused_link.should eq -1
    tb.extra_selections.should be_empty
    tb._listener ctl(::Tput::Key::Enter)
    clicked.should be_empty
  end

  it "does not follow a click when off" do
    s = headless_screen(40, 8)
    tb = linked_tb s
    clicked = [] of String
    tb.on(Crysterm::Event::AnchorClick) { |e| clicked << e.url }
    tb.links_enabled = false
    click s, 4, 0
    clicked.should be_empty
    tb.links_enabled = true
    # The other link: a second press on the same spot would read as a double.
    click s, 12, 0
    clicked.should eq ["u://2"]
  end
end

describe "TextBrowser#link_clicks" do
  it "defaults to a single click" do
    s = headless_screen(40, 8)
    linked_tb(s).link_clicks.should eq 1
  end

  it "with 2, a single click does not follow and a double click does" do
    s = headless_screen(40, 8)
    tb = linked_tb s
    tb.link_clicks = 2
    clicked = [] of String
    tb.on(Crysterm::Event::AnchorClick) { |e| clicked << e.url }
    click s, 4, 0
    clicked.should be_empty
    # The first click still placed the caret, as on ordinary text.
    tb.cursor_pos.should eq 4
    click s, 4, 0
    s.click_count.should eq 2
    clicked.should eq ["u://1"]
  end

  it "accepts 1 or 2 only" do
    s = headless_screen(40, 8)
    tb = linked_tb s
    tb.link_clicks = 2
    tb.link_clicks = 1
    expect_raises(ArgumentError) { tb.link_clicks = 3 }
    expect_raises(ArgumentError) { tb.link_clicks = 0 }
    tb.link_clicks.should eq 1
  end

  describe "TextBrowser links off and double clicks, with the rest of the row" do
    it "keeps the widget style's own underline on a disabled link" do
      s = headless_screen(40, 8)
      tb = linked_tb s
      tb.style.underline = true
      tb.links_enabled = false
      s.repaint
      link = Attr.flags(s.cell_rows[0][3].attr)
      plain = Attr.flags(s.cell_rows[0][0].attr)
      (link & Attr::UNDERLINE.to_i64).should eq Attr::UNDERLINE.to_i64
      link.should eq plain
    end

    it "leaves no word selected after the double click that followed a link" do
      s = headless_screen(40, 8)
      tb = linked_tb s
      tb.link_clicks = 2
      clicked = [] of String
      tb.on(Crysterm::Event::AnchorClick) { |e| clicked << e.url }
      click s, 4, 0
      click s, 4, 0
      clicked.should eq ["u://1"]
      tb.selection?.should be_false # the text's double-click word select was the link's click
    end
  end
end
