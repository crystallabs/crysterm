require "./spec_helper"

include Crysterm

# `Widget#delete_line` (and `delete_top`/`delete_bottom`/`remove_first_line`/`remove_last_line`)
# must not raise on an empty widget: empty content leaves `@wrapped_lines.fake` empty,
# and reaching `ftor[-1]` / `fake.delete_at` on empty arrays raises
# `IndexError`. Mirrors the guard already proven for `#insert_line`/`#line`.
describe "Widget#delete_line on empty content" do
  it "remove_last_line on a freshly built widget does not raise" do
    box = Widget::Box.new parent: headless_screen(default_quit_keys: true)
    box.remove_last_line 1
    box.lines.should eq [] of String
  end

  it "delete_line (delete last) on a freshly built widget does not raise" do
    box = Widget::Box.new parent: headless_screen(default_quit_keys: true)
    box.delete_line
    box.lines.should eq [] of String
  end

  it "remove_first_line / delete_top / delete_bottom on empty content do not raise" do
    box = Widget::Box.new parent: headless_screen(default_quit_keys: true)
    box.remove_first_line 1
    box.delete_top 1
    box.delete_bottom 1
    box.lines.should eq [] of String
  end

  it "delete_line on content that was cleared to empty does not raise" do
    box = Widget::Box.new parent: headless_screen(default_quit_keys: true)
    box.set_content "one\ntwo"
    box.set_content ""
    box.delete_line
    box.lines.should eq [] of String
  end

  it "still deletes correctly once content exists" do
    box = Widget::Box.new parent: headless_screen(default_quit_keys: true)
    box.set_content "one\ntwo\nthree"
    box.delete_line index: 1
    box.lines.should eq ["one", "three"]
    box.remove_last_line 1
    box.lines.should eq ["one"]
  end
end
