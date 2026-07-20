require "./spec_helper"

include Crysterm

# BUGS12 regression coverage for `Widget::TextBrowser`:
#   #33 — Enter with no focused link must NOT activate the last link.
#   #34 — First Shift-Tab from the unfocused state must select the last link.
#   #35 — #back/#forward must not lose a history entry when the loader declines.

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
  s.repaint
  tb
end

private def ctl(k : ::Tput::Key)
  Crysterm::Event::KeyPress.new '\0', k
end

private def linked_doc
  TextDocument.from_markdown("go [one](u://1) and [two](u://2)")
end

describe "BUGS12 #33 Enter without a focused link" do
  it "does not activate any link when @focused_link is -1" do
    s = tb_screen
    tb = new_tb s
    tb.document = linked_doc
    tb.focused_link.should eq -1

    clicked = [] of String
    tb.on(Crysterm::Event::AnchorClick) { |e| clicked << e.url }

    # Enter with nothing focused: previously activated links[-1] (the last).
    tb._listener ctl(::Tput::Key::Enter)
    clicked.should be_empty
  end

  it "still activates the focused link once Tab selects one" do
    s = tb_screen
    tb = new_tb s
    tb.document = linked_doc
    clicked = [] of String
    tb.on(Crysterm::Event::AnchorClick) { |e| clicked << e.url }

    tb._listener ctl(::Tput::Key::Tab)
    tb._listener ctl(::Tput::Key::Enter)
    clicked.should eq ["u://1"]
  end
end

describe "BUGS12 #34 First Shift-Tab from unfocused state" do
  it "selects the last link, not the second-to-last" do
    s = tb_screen
    tb = new_tb s
    tb.document = linked_doc
    tb.focused_link.should eq -1

    tb.focus_link(-1).should be_true
    tb.focused_link.should eq 1 # last of two links
  end

  it "first Tab from unfocused state selects the first link" do
    s = tb_screen
    tb = new_tb s
    tb.document = linked_doc
    tb.focus_link(1).should be_true
    tb.focused_link.should eq 0
  end
end

describe "BUGS12 #35 back/forward preserve history on a declining loader" do
  it "keeps the history entry when the loader declines during #back" do
    s = tb_screen
    tb = new_tb s
    available = {"a", "b"}
    tb.loader = ->(url : String) do
      available.includes?(url) ? TextDocument.from_markdown("page #{url}") : nil
    end

    tb.source = "a"
    tb.activate_link "b"
    tb.source.should eq "b"
    tb.backward_available?.should be_true

    # Loader now declines "a": back must fail but keep it in history.
    available = {"b"}
    tb.backward.should be_false
    tb.source.should eq "b"
    tb.backward_available?.should be_true

    # Once the loader accepts "a" again, back still works.
    available = {"a", "b"}
    tb.backward.should be_true
    tb.source.should eq "a"
    tb.backward_available?.should be_false
  end

  it "keeps the future entry when the loader declines during #forward" do
    s = tb_screen
    tb = new_tb s
    available = {"a", "b"}
    tb.loader = ->(url : String) do
      available.includes?(url) ? TextDocument.from_markdown("page #{url}") : nil
    end

    tb.source = "a"
    tb.activate_link "b"
    tb.backward.should be_true
    tb.source.should eq "a"
    tb.forward_available?.should be_true

    # Loader now declines "b": forward must fail but keep it in the future.
    available = {"a"}
    tb.forward.should be_false
    tb.source.should eq "a"
    tb.forward_available?.should be_true

    # Once the loader accepts "b" again, forward still works.
    available = {"a", "b"}
    tb.forward.should be_true
    tb.source.should eq "b"
    tb.forward_available?.should be_false
  end
end
