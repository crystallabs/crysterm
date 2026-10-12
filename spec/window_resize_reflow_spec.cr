require "./spec_helper"

include Crysterm

# A terminal resize (`Window#handle_resize`) reaches each widget the way a
# `set_geometry` resize does (`Widget#emit_resize`): the content is reflowed
# to the new width before the widget's `Event::Resize` handlers run, so a
# handler reading the wrapped lines sees the new layout, not the old width's.
describe "Window#handle_resize" do
  it "reflows a widget's content before its Resize handlers run" do
    s = headless_screen # 80 x 24, neither axis pinned, so it follows the device
    box = Widget::Box.new parent: s, left: 0, top: 0, width: "50%", height: 5, content: "word " * 40
    s.repaint
    before = box.wrapped_lines.width
    before.should be > 0

    seen = [] of Int32
    box.on(Event::Resize) { seen << box.wrapped_lines.width }
    s.screen.resize 40, 24
    s.handle_resize Event::Resize.new

    seen.size.should eq 1
    seen[0].should eq box.wrapped_lines.width
    seen[0].should eq before - 20
    s.destroy
  end
end
