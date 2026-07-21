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
    it "emits Event::Resize when {{ dim.id }} changes" do
      b = Widget::Box.new
      fired = 0
      b.on(Crysterm::Event::Resize) { fired += 1 }

      b.{{ dim.id }} = 7
      fired.should eq 1

      # Idempotent: re-setting the same value does not re-emit (mirrors the
      # `return if @x == val` guard on `width=`/`height=`).
      b.{{ dim.id }} = 7
      fired.should eq 1

      b.{{ dim.id }} = nil
      fired.should eq 2
    end
  {% end %}
end

# `Widget#set_geometry` assigns left/top/width/height in one pass, coalescing
# the events the four independent setters would each fire: at most one `Move`
# (if position changed) + one `Resize` (if size changed), and a full no-op when
# nothing changed. Used by `Layout#place_child` so a repositioned child runs one
# `mark_dirty` + one `process_content` instead of up to four each.
describe "Widget#set_geometry" do
  it "emits exactly one Move and one Resize for a combined change" do
    b = Widget::Box.new
    moves = 0
    resizes = 0
    b.on(Crysterm::Event::Move) { moves += 1 }
    b.on(Crysterm::Event::Resize) { resizes += 1 }

    b.set_geometry 1, 2, 10, 5

    moves.should eq 1
    resizes.should eq 1
    b.left.should eq 1
    b.top.should eq 2
    b.width.should eq 10
    b.height.should eq 5
  end

  it "is a full no-op (no events) when nothing changed" do
    b = Widget::Box.new
    b.set_geometry 1, 2, 10, 5

    moves = 0
    resizes = 0
    b.on(Crysterm::Event::Move) { moves += 1 }
    b.on(Crysterm::Event::Resize) { resizes += 1 }

    b.set_geometry 1, 2, 10, 5

    moves.should eq 0
    resizes.should eq 0
  end

  it "emits only Move when just the position changes" do
    b = Widget::Box.new
    b.set_geometry 1, 2, 10, 5

    moves = 0
    resizes = 0
    b.on(Crysterm::Event::Move) { moves += 1 }
    b.on(Crysterm::Event::Resize) { resizes += 1 }

    b.set_geometry 3, 4, 10, 5

    moves.should eq 1
    resizes.should eq 0
  end

  it "emits only Resize when just the size changes" do
    b = Widget::Box.new
    b.set_geometry 1, 2, 10, 5

    moves = 0
    resizes = 0
    b.on(Crysterm::Event::Move) { moves += 1 }
    b.on(Crysterm::Event::Resize) { resizes += 1 }

    b.set_geometry 1, 2, 20, 9

    moves.should eq 0
    resizes.should eq 1
  end

  it "runs process_content exactly once for a size change (via a single Resize)" do
    # Every widget subscribes `on(Resize) { process_content }`; count Resize
    # dispatches as a proxy for process_content runs. A width+height change
    # through the four independent setters would fire two Resizes (two
    # process_content runs) — set_geometry coalesces to one.
    b = Widget::Box.new
    b.set_geometry 1, 2, 10, 5

    resizes = 0
    b.on(Crysterm::Event::Resize) { resizes += 1 }

    b.set_geometry 1, 2, 20, 9

    resizes.should eq 1
  end
end
