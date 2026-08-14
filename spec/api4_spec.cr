require "./spec_helper"

include Crysterm

private def headless_window(width = 20, height = 6, inline = false)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height, inline: inline)
end

# Coverage for the API4 (Qt-fidelity polish) additions that were implemented in
# this round. Each block maps to an A4-* finding.
describe "API4 additions" do
  describe "Application lifecycle" do
    it "primary_screen is the active window's device (A4-01)" do
      app = Application.new
      win = headless_window
      app.add win
      app.primary_screen.should eq win.screen
    end

    it "primary_screen is nil with no windows (A4-01)" do
      Application.new.primary_screen.should be_nil
    end

    it "active_window= activates a window (A4-02)" do
      app = Application.new
      a = headless_window
      b = headless_window
      app.add a
      app.add b
      app.active_window.should eq b
      app.active_window = a
      app.active_window.should eq a
    end
  end

  describe "Window" do
    it "#activate returns self (A4-04)" do
      app = Application.new
      win = headless_window
      app.add win
      win.activate.should be win
    end

    it "inline: keyword and #inline? (A4-06)" do
      headless_window.inline?.should be_false # alternate default
      headless_window(inline: true).inline?.should be_true
      headless_window(inline: true).alternate?.should be_false
    end
  end

  describe "Widget#child_at (A4-16)" do
    it "returns the topmost descendant covering a point, nil otherwise" do
      win = headless_window(width: 20, height: 10)
      outer = Crysterm::Widget::Box.new parent: win, left: 0, top: 0, width: 20, height: 10
      inner = Crysterm::Widget::Box.new parent: outer, left: 2, top: 1, width: 6, height: 3
      win.update
      outer.child_at(3, 2).should eq inner # absolute coords
      outer.child_at(Crysterm::Point.new(3, 2)).should eq inner
      outer.child_at(19, 9).should be_nil
    end
  end

  describe "Colors.lighter / .darker (A4-34)" do
    it "lighter raises and darker lowers lightness" do
      base = 0x808080
      Colors.luminance(Colors.lighter(base)).should be > Colors.luminance(base)
      Colors.luminance(Colors.darker(base)).should be < Colors.luminance(base)
    end

    it "factor <= 0 returns the color unchanged" do
      Colors.lighter(0x123456, 0).should eq 0x123456
      Colors.darker(0x123456, -5).should eq 0x123456
    end
  end

  describe "Subscription teardown vocabulary (A4-55)" do
    it "Subscription#dispose / #disposed?" do
      win = headless_window
      sub = Subscription.new
      sub.disposed?.should be_true
      sub.on(win, Crysterm::Event::Resize) { }
      sub.disposed?.should be_false
      sub.dispose
      sub.disposed?.should be_true
    end

    it "Subscriptions#dispose / #disposed?" do
      win = headless_window
      subs = Subscriptions.new
      subs.disposed?.should be_true
      subs.on(win, Crysterm::Event::Resize) { }
      subs.disposed?.should be_false
      subs.dispose
      subs.disposed?.should be_true
    end
  end

  describe "Button Event::Toggled (A4-58)" do
    it "a checkable button emits Toggled(bool) on toggle" do
      win = headless_window
      btn = Crysterm::Widget::Button.new parent: win, checkable: true
      seen = [] of Bool
      btn.on(Crysterm::Event::Toggled) { |e| seen << e.checked }
      btn.toggle
      btn.toggle
      seen.should eq [true, false]
    end
  end

  describe "CheckBox#set_partial (A4-66)" do
    it "sets the partially-checked state on a tristate box" do
      win = headless_window
      cb = Crysterm::Widget::CheckBox.new tristate: true, parent: win
      cb.set_partial
      cb.partial?.should be_true
    end
  end

  describe "input on_* block sugar (A4-61)" do
    it "TextEditing#on_text_change" do
      win = headless_window
      le = Crysterm::Widget::LineEdit.new parent: win
      seen = nil
      le.on_text_change { |t| seen = t }
      le.value = "hi"
      seen.should eq "hi"
    end

    it "ComboBox#on_current_index_change" do
      win = headless_window
      combo = Crysterm::Widget::ComboBox.new(["a", "b", "c"], parent: win)
      idx = nil
      combo.on_current_index_change { |i| idx = i }
      combo.current_index = 2
      idx.should eq 2
    end
  end

  describe "TextCursor#insert_block char_format (A4-56)" do
    it "sets the pending typing format for the new block" do
      doc = TextDocument.new
      c = TextCursor.new(doc)
      c.insert_text "ab"
      fmt = c.char_format
      c.insert_block(nil, fmt)
      c.char_format.should eq fmt
    end
  end

  describe "Message static helpers (A4-37)" do
    it "builds a Message parented to the window" do
      win = headless_window(width: 40, height: 10)
      msg = Crysterm::Widget::Message.information(win, "hello")
      msg.should be_a Crysterm::Widget::Message
      msg.window.should eq win
    end
  end
end
