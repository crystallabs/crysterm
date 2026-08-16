require "./spec_helper"

include Crysterm

# A reactive repaint request must MARK
# DAMAGE, not merely ring the render doorbell.
#
# `Binding#run`, `Effect#run` and `bind_items`' change handler each promise "a
# repaint is scheduled after this ran". A bare
# `window?.try &.update` only rings the coalescing doorbell — it does not
# enter the owner into the window's `@damage_dirty_roots` set. Under
# `OptimizationFlag::DamageTracking` (the default, see
# `Config.render_optimization`) the frame that doorbell buys then finds an
# *empty* dirty set and takes the selective path's "nothing changed" shortcut
# (`Window#damage_try_composite`), carrying the previous frame's buffer over
# verbatim: the reactive change never reaches the screen. With tracking off the
# same code renders correctly, since every frame is a full re-composite.
#
# It only bites when the block's mutation isn't itself observed by damage
# tracking — an in-place `Style` write, a plain ivar the widget renders from —
# which is exactly the case the doorbell was there to cover. Mutations made
# through a tracked setter (`content=`, geometry, the `set_content` behind
# `bind_items`' row patches) mark themselves and were always fine.
#
# The fix routes all three sites through `Widget#update!`
# (`damage_mark_dirty` + a window `update`), matching what `reactive_property`
# does (widget `update` + window `update`).

private def rx_screen(damage : Bool)
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 40,
    height: 10,
    default_quit_keys: false,
    optimization: damage ? Crysterm::OptimizationFlag::DamageTracking : Crysterm::OptimizationFlag::None)
end

# Asserts the two windows' cell buffers are identical, like
# `spec/damage_tracking_spec.cr`'s namesake.
private def assert_same_lines(a : Crysterm::Window, b : Crysterm::Window, ctx = "")
  a.cell_rows.size.should eq b.cell_rows.size
  a.cell_rows.each_index do |y|
    la = a.cell_rows[y]
    lb = b.cell_rows[y]
    la.size.should eq lb.size
    la.size.times do |x|
      ca = la[x]
      cb = lb[x]
      if ca.attr != cb.attr || ca.char != cb.char || la.grapheme_at?(x) != lb.grapheme_at?(x)
        fail "cell mismatch at (#{y},#{x}) #{ctx}: " \
             "full=(attr=#{cb.attr},char=#{cb.char.inspect},g=#{lb.grapheme_at?(x).inspect}) " \
             "damage=(attr=#{ca.attr},char=#{ca.char.inspect},g=#{la.grapheme_at?(x).inspect})"
      end
    end
  end
end

# One buffer row as `char + attr` text, for "did the frame change at all?"
# guards — an example that renders nothing twice must not pass.
private def row_signature(screen : Crysterm::Window, y : Int32) : String
  String.build do |s|
    line = screen.cell_rows[y]
    line.size.times { |x| s << line[x].char << line[x].attr << ' ' }
  end
end

# A box small enough that the selective path stays cheaper than a full frame, so
# the fast path really engages instead of falling back and hiding the bug.
private def rx_box(screen)
  Crysterm::Widget::Box.new(
    parent: screen, top: 1, left: 1, width: 10, height: 3,
    style: Crysterm::Style.new(bg: 0x000080), content: "hi")
end

describe "reactive repaints under damage tracking" do
  it "shows a Binding's untracked mutation" do
    plain = rx_screen false
    dmg = rx_screen true
    pb = rx_box plain
    db = rx_box dmg
    color = Crysterm::Reactive::Property.new 0x000080

    # The blocks mutate the style IN PLACE: nothing there marks the widget
    # dirty, so the repaint the binding schedules is all that can paint it.
    Crysterm::Reactive.bind(pb, color) { pb.style.bg = color.value }
    Crysterm::Reactive.bind(db, color) { db.style.bg = color.value }

    plain.repaint
    dmg.repaint
    assert_same_lines dmg, plain, "(initial)"
    before = row_signature plain, 1

    color.value = 0x00aa00
    plain.repaint
    dmg.repaint

    row_signature(plain, 1).should_not eq before # the mutation is visible at all
    assert_same_lines dmg, plain, "(after the binding fired)"
    dmg.damage_fast_frames.should be > 0
  end

  it "shows an Effect's untracked mutation" do
    plain = rx_screen false
    dmg = rx_screen true
    pb = rx_box plain
    db = rx_box dmg
    color = Crysterm::Reactive::Property.new 0x000080

    Crysterm::Reactive.effect(pb) { pb.style.bg = color.value }
    Crysterm::Reactive.effect(db) { db.style.bg = color.value }

    plain.repaint
    dmg.repaint
    assert_same_lines dmg, plain, "(initial)"
    before = row_signature plain, 1

    color.value = 0x00aa00
    plain.repaint
    dmg.repaint

    row_signature(plain, 1).should_not eq before
    assert_same_lines dmg, plain, "(after the effect re-ran)"
    dmg.damage_fast_frames.should be > 0
  end

  it "shows bind_items' row patches" do
    plain = rx_screen false
    dmg = rx_screen true
    pv = Crysterm::Widget::List.new parent: plain, top: 0, left: 0, width: 20, height: 6
    dv = Crysterm::Widget::List.new parent: dmg, top: 0, left: 0, width: 20, height: 6
    pl = Crysterm::Reactive::ObservableList(String).new %w[Ada Alan]
    dl = Crysterm::Reactive::ObservableList(String).new %w[Ada Alan]
    Crysterm::Reactive.bind_items(pv, pl, &.itself)
    Crysterm::Reactive.bind_items(dv, dl, &.itself)

    plain.repaint
    dmg.repaint
    assert_same_lines dmg, plain, "(initial)"

    # A row patch goes through `set_item` -> `Widget#set_content`, which marks
    # the item box dirty itself; these steps pin that the reactive frame lands
    # correctly all the same.
    before = row_signature plain, 0
    pl[0] = "Ada L."
    dl[0] = "Ada L."
    plain.repaint
    dmg.repaint
    row_signature(plain, 0).should_not eq before
    assert_same_lines dmg, plain, "(row updated)"

    pl << "Grace"
    dl << "Grace"
    plain.repaint
    dmg.repaint
    assert_same_lines dmg, plain, "(row appended)"

    pl.delete_at 0
    dl.delete_at 0
    plain.repaint
    dmg.repaint
    assert_same_lines dmg, plain, "(row removed)"
  end
end
