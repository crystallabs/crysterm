require "./spec_helper"

# `Neovim::Handler` with several views of one buffer (`#add_view`), as Vim
# shows one buffer in several windows: widgets on one `TextDocument`, in
# windows of their own, whose keys all go to the one Neovim buffer.

private def nvv_window
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 40, height: 10, default_quit_keys: false)
end

private def nvv_type(w, text : String)
  text.scan(/<[^>]+>|./m) do |m|
    e = m[0] == "<Esc>" ? Crysterm::Event::KeyPress.new('\e', Tput::Key::Escape) : Crysterm::Event::KeyPress.new(m[0][0], nil)
    w.emit e
  end
end

# Two `PlainTextEdit`s in two windows, showing one document.
private def nvv_views(text = "abc")
  wa = nvv_window
  wb = nvv_window
  a = Crysterm::Widget::PlainTextEdit.new parent: wa, width: 40, height: 8
  a.value = text
  b = Crysterm::Widget::PlainTextEdit.new parent: wb, width: 30, height: 6
  b.document = a.document
  {wa, wb, a, b}
end

describe Crysterm::Neovim::Handler do
  unless Crysterm::Neovim.available?
    pending "needs nvim in PATH"
    next
  end

  it "takes keys from every view into the one buffer, the caret in the view typed into" do
    wa, wb, a, b = nvv_views
    h = Crysterm::Neovim::Handler.new
    modes = [] of Crysterm::Neovim::Mode
    h.on(Crysterm::Event::ViModeChanged) { |e| modes << e.mode }
    begin
      h.attach(a).should be_true
      h.add_view(b).should be_true
      h.add_view(b).should be_true
      h.views.should eq [a, b] of Crysterm::Widget
      h.active_widget.should be a

      # B's caret is where Neovim's cursor goes once B has the keys.
      b.cursor_pos = 2
      nvv_type b, "ix<Esc>"
      h.active_widget.should be b
      a.value.should eq "abxc"
      b.value.should eq "abxc"
      modes.should eq [Crysterm::Neovim::Mode::Insert, Crysterm::Neovim::Mode::Normal]
      nvv_type b, "$"
      b.cursor_position.should eq 3

      # Neovim's undo, from the other view.
      nvv_type a, "u"
      h.active_widget.should be a
      a.value.should eq "abc"
      b.value.should eq "abc"
    ensure
      h.detach
      wa.destroy
      wb.destroy
    end
  end

  it "sends an edit made in one view to Neovim once" do
    wa, wb, a, b = nvv_views "one\ntwo"
    h = Crysterm::Neovim::Handler.new
    begin
      h.attach(a).should be_true
      h.add_view(b).should be_true
      b.document.set_plain_text "uno\ndos"
      nvv_type b, "jx"
      a.value.should eq "uno\nos"
      nvv_type a, "u"
      a.value.should eq "uno\ndos"
    ensure
      h.detach
      wa.destroy
      wb.destroy
    end
  end

  it "gives every view the mode's caret shape, and its own back when removed" do
    wa, wb, a, b = nvv_views
    h = Crysterm::Neovim::Handler.new
    begin
      h.attach(a).should be_true
      own = b.cursor_shape
      h.add_view(b).should be_true
      b.cursor_shape.should eq Tput::CursorShape::Block
      nvv_type a, "i"
      a.cursor_shape.should eq Tput::CursorShape::Line
      b.cursor_shape.should eq Tput::CursorShape::Line
      nvv_type a, "<Esc>"
      h.remove_view b
      h.views.should eq [a] of Crysterm::Widget
      b.cursor_shape.should eq own
      # B's keys no longer reach Neovim.
      nvv_type b, "x"
      h.sync
      a.value.should eq "abc"
    ensure
      h.detach
      wa.destroy
      wb.destroy
    end
  end

  it "goes on with the views left when the first is removed" do
    wa, wb, a, b = nvv_views
    h = Crysterm::Neovim::Handler.new
    begin
      h.attach(a).should be_true
      h.add_view(b).should be_true
      h.remove_view a
      h.attached?.should be_true
      h.widget.should be b
      h.active_widget.should be b
      nvv_type b, "Ay<Esc>"
      b.value.should eq "abcy"
      # The document's changes are still followed, through B.
      a.value = "new"
      nvv_type b, "0x"
      b.value.should eq "ew"
    ensure
      h.detach
      wa.destroy
      wb.destroy
    end
  end

  it "stays on the views left when one is destroyed, and ends with the last" do
    wa, wb, a, b = nvv_views
    h = Crysterm::Neovim::Handler.new
    exits = 0
    h.on(Crysterm::Event::ProcessExited) { exits += 1 }
    h.attach(a).should be_true
    client = h.client.not_nil!
    h.add_view(b).should be_true
    nvv_type b, "x"
    h.active_widget.should be b

    wb.destroy
    h.attached?.should be_true
    h.views.should eq [a] of Crysterm::Widget
    h.active_widget.should be a
    # Neovim's cursor goes to A's own caret, at the end.
    nvv_type a, "x"
    a.value.should eq "b"

    wa.destroy
    h.attached?.should be_false
    h.views.should be_empty
    h.active_widget.should be_nil
    client.running?.should be_false
    sleep 50.milliseconds
    exits.should eq 0
  end

  it "refuses a view of another document, or while detached" do
    wa, wb, a, b = nvv_views
    c = Crysterm::Widget::PlainTextEdit.new parent: wb, top: 7, width: 30, height: 2
    c.value = "abc"
    h = Crysterm::Neovim::Handler.new
    begin
      h.add_view(b).should be_false
      h.attach(a).should be_true
      h.add_view(c).should be_false
      h.views.should eq [a] of Crysterm::Widget
      # A view given another document is let go of.
      h.add_view(b).should be_true
      b.document = Crysterm::TextDocument.new
      h.views.should eq [a] of Crysterm::Widget
    ensure
      h.detach
      wa.destroy
      wb.destroy
    end
  end
end
