require "./spec_helper"

include Crysterm

# A size constraint (`min_width`/`max_width`/`min_height`/`max_height`) change
# alters the widget's effective `awidth`/`aheight` just as `width=`/`height=` do,
# so it must emit `Event::Resize` — otherwise listeners (`Mixin::ItemView#on_resize`,
# `Mixin::TextEditing`'s Resize->`_update_cursor`) never fire and scroll/cursor
# state goes stale after a `max-height`/`min-width` change.
#
# A plain unattached `Box` is enough headless: `emit`/`on` work without a
# screen and `mark_dirty` no-ops when detached.
describe "Widget size-constraint setters emit Resize" do
  {% for dim in %w[min_width max_width min_height max_height] %}
    it "emits Event::Resize when {{dim.id}} changes" do
      b = Widget::Box.new
      fired = 0
      b.on(Crysterm::Event::Resize) { fired += 1 }

      b.{{dim.id}} = 7
      fired.should eq 1

      # Idempotent: re-setting the same value does not re-emit (mirrors the
      # `return if @x == val` guard on `width=`/`height=`).
      b.{{dim.id}} = 7
      fired.should eq 1

      b.{{dim.id}} = nil
      fired.should eq 2
    end
  {% end %}
end
