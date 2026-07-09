require "./spec_helper"

include Crysterm

# `Widget::TextBrowser` (TEXTEDIT.md Phase 4): link enumeration, keyboard
# (Tab-cycle + Enter) and pointer activation, and source navigation history
# through the application-provided `loader`.

private def tb_screen(width = 40, height = 8)
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: width,
    height: height)
end

private def new_tb(s)
  tb = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: 40, height: 8
  s._render
  tb
end

private def ctl(k : ::Tput::Key)
  Crysterm::Event::KeyPress.new '\0', k
end

private def linked_doc
  TextDocument.from_markdown("go [one](u://1) and [two](u://2)")
end

describe Widget::TextBrowser do
  it "is read-only by default and enumerates links" do
    s = tb_screen
    tb = new_tb s
    tb.read_only?.should be_true
    tb.document = linked_doc
    tb.links.size.should eq 2
    tb.links[0].url.should eq "u://1"
    tb.links[0].from.should eq 3
    tb.links[0].to.should eq 6
    tb.links[1].url.should eq "u://2"
  end

  it "cycles link focus with Tab and activates with Enter" do
    s = tb_screen
    tb = new_tb s
    tb.document = linked_doc
    clicked = [] of String
    tb.on(Crysterm::Event::AnchorClick) { |e| clicked << e.url }

    tb._listener ctl(::Tput::Key::Tab)
    tb.focused_link.should eq 0
    tb._listener ctl(::Tput::Key::Tab)
    tb.focused_link.should eq 1
    tb._listener ctl(::Tput::Key::Tab)
    tb.focused_link.should eq 0 # wraps
    tb._listener ctl(::Tput::Key::ShiftTab)
    tb.focused_link.should eq 1

    tb._listener ctl(::Tput::Key::Enter)
    clicked.should eq ["u://2"]
  end

  it "activates a link under a mouse click" do
    s = tb_screen
    tb = new_tb s
    tb.document = linked_doc
    s._render
    clicked = [] of String
    tb.on(Crysterm::Event::AnchorClick) { |e| clicked << e.url }

    # "go one and two" — 'o' of "one" is at column 4.
    s.dispatch_mouse ::Tput::Mouse::Event.new(
      ::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left, 4, 0, source: :test)
    clicked.should eq ["u://1"]

    # A click on plain text activates nothing.
    s.dispatch_mouse ::Tput::Mouse::Event.new(
      ::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left, 8, 0, source: :test)
    clicked.should eq ["u://1"]
  end

  it "navigates sources through the loader with history" do
    s = tb_screen
    tb = new_tb s
    pages = {
      "a" => "page a [next](b)",
      "b" => "page b",
    }
    tb.loader = ->(url : String) { pages[url]?.try { |md| TextDocument.from_markdown(md) } }

    sources = [] of String
    tb.on(Crysterm::Event::SourceChange) { |e| sources << e.url }

    tb.source = "a"
    tb.source.should eq "a"
    tb.document.to_plain_text.should contain "page a"
    tb.back_available?.should be_false

    # Following the link records history and swaps the document.
    tb.activate_link "b"
    tb.source.should eq "b"
    tb.document.to_plain_text.should eq "page b"
    tb.back_available?.should be_true

    # Backspace = back; forward returns.
    tb._listener ctl(::Tput::Key::Backspace)
    tb.source.should eq "a"
    tb.forward_available?.should be_true
    tb.forward.should be_true
    tb.source.should eq "b"

    sources.should eq ["a", "b", "a", "b"]

    # A URL the loader declines changes nothing.
    tb.activate_link "missing"
    tb.source.should eq "b"
  end

  it "renders the focused link inverse and keeps user extra selections" do
    s = tb_screen
    tb = new_tb s
    tb.document = linked_doc
    s._render
    tb.focus_link(1).should be_true
    s._render
    # "go |one|" — link text cells render inverse.
    (Attr.flags(s.lines[0][3].attr) & Attr::REVERSE).should_not eq 0
    (Attr.flags(s.lines[0][0].attr) & Attr::REVERSE).should eq 0
    # Moving focus moves the highlight instead of stacking a second one.
    tb.focus_link(1)
    s._render
    (Attr.flags(s.lines[0][3].attr) & Attr::REVERSE).should eq 0
    tb.extra_selections.size.should eq 1
  end

  it "documents without links refuse link focus" do
    s = tb_screen
    tb = new_tb s
    tb.document = TextDocument.new("plain")
    tb.focus_link(1).should be_false
    tb.focused_link.should eq -1
  end
end
