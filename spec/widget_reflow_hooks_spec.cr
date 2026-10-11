require "./spec_helper"

# A widget carries no `Resize`/`Attached` subscriptions of its own: content is
# reflowed through `Widget#emit_resize` / `#reflow_on_attach`, before the
# event reaches any handler.
private class ReflowBox < Crysterm::Widget::Box
  getter reflows = 0

  def process_content(no_tags = false, awidth_hint : Int32? = nil)
    @reflows += 1
    super
  end
end

describe "Widget content reflow hooks" do
  it "registers no Resize or Attached handlers, and reflows once while constructing" do
    s = headless_screen(40, 10)
    box = ReflowBox.new parent: s, width: 10, height: 3, content: "hello world"
    box.handlers(Crysterm::Event::Resize).size.should eq 0
    box.handlers(Crysterm::Event::Attached).size.should eq 0
    box.reflows.should eq 1            # the constructor's own `set_content`; the append inside it adds none
    box.wrapped_lines.size.should eq 2 # "hello" / "world" at width 10
  ensure
    s.try &.destroy
  end

  it "reflows before Resize handlers run" do
    s = headless_screen(40, 10)
    box = ReflowBox.new parent: s, width: 10, height: 3, content: "hello world"
    seen = -1
    rows = -1
    box.on(Crysterm::Event::Resize) do
      seen = box.reflows
      rows = box.wrapped_lines.size
    end
    before = box.reflows
    box.width = 20
    seen.should eq before + 1
    rows.should eq 1
    box.wrapped_lines.width.should eq 20
  ensure
    s.try &.destroy
  end

  it "reflows a set_geometry resize and the layout-assigned geometry" do
    s = headless_screen(40, 10)
    box = ReflowBox.new parent: s, width: 10, height: 3, content: "hello world"
    box.set_geometry 0, 0, 20, 3
    box.wrapped_lines.size.should eq 1
    box.set_geometry 0, 0, 10, 3
    box.wrapped_lines.size.should eq 2
  ensure
    s.try &.destroy
  end

  it "reflows on attach, before Attached handlers run" do
    s = headless_screen(40, 10)
    other = headless_screen(60, 10)
    box = ReflowBox.new parent: other, width: 10, height: 3, content: "hello world"
    seen = -1
    box.on(Crysterm::Event::Attached) { seen = box.reflows }
    before = box.reflows
    s.append box
    seen.should eq before + 1
    box.window?.same?(s).should be_true
  ensure
    s.try &.destroy
    other.try &.destroy
  end

  it "reflows every widget of a reparented subtree" do
    s = headless_screen(40, 10)
    other = headless_screen(60, 10)
    outer = Crysterm::Widget::Box.new parent: other, width: 12, height: 5
    inner = ReflowBox.new parent: outer, width: 10, height: 3, content: "hello world"
    before = inner.reflows
    s.append outer
    inner.reflows.should eq before + 1
    inner.window?.same?(s).should be_true
  ensure
    s.try &.destroy
    other.try &.destroy
  end
end
