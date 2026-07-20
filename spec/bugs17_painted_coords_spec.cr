require "./spec_helper"

include Crysterm

# Regression spec for BUGS17 B17-18 (ColorDialog), B17-22 (Splitter) and
# B17-23 (SizeGrip): mouse/drag hit-tests and resize math used layout coords
# (`aleft`/`atop`) where the *painted* origin (`@lpos`) is required. Inside a
# scrolled container the two differ by the enclosing scroll base, so a drag or
# click landed offset by the scroll amount. The fixes resolve the pointer
# against the painted origin (`Widget#painted_origin`, or the painted `lpos`
# rects directly), matching `Mixin::TrackGeometry#pointer_offset`.
#
# All three cases are exercised inside a `scrollable: true` container scrolled
# down `k` rows, so painted != layout; the unscrolled path stays byte-identical
# (covered by the existing bugs12/bugs14/qt specs).

private def pc_screen(w = 100, h = 50)
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

private def pc_mouse(action : Tput::Mouse::Action, x : Int32, y : Int32)
  Tput::Mouse::Event.new(action, Tput::Mouse::Button::Left, x, y)
end

describe "BUGS17 B17-22: Splitter divider drag inside a scrolled container" do
  it "lands the divider under the painted pointer, not offset by the scroll base" do
    s = pc_screen
    sc = Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 40,
      height: 24, scrollable: true
    sp = Crysterm::Widget::Splitter.new parent: sc,
      orientation: Tput::Orientation::Vertical, top: 6, left: 2,
      width: 30, height: 12
    sp.add_widget Crysterm::Widget::Box.new
    sp.add_widget Crysterm::Widget::Box.new
    # A child far below gives the container a real scroll extent.
    Crysterm::Widget::Box.new parent: sc, top: 40, left: 0, width: 4, height: 1
    s.repaint

    k = 3
    sc.scroll_to k, true
    s.repaint

    lp = sp.lpos.not_nil!
    # Sanity: the splitter is painted k rows above its layout position.
    lp.yi.should eq sp.atop - k

    div = sp.dividers[0]
    target = 5 # a content-relative divider offset well inside the clamp range

    data = Crysterm::DragData.new(div)
    # Painted pointer row for the wanted content offset.
    py = lp.yi + sp.itop + target
    session = Crysterm::DragSession.new(div, data, lp.xi, py, Crysterm::DragSensor::Mouse)
    div.emit Crysterm::Event::Drag, session

    # Post-fix: the divider lands exactly at the wanted offset. Pre-fix it used
    # the layout origin (atop == lp.yi + k), yielding target - k == 2.
    sp.divider_position(0).should eq target
  end
end

describe "BUGS17 B17-23: SizeGrip drag-resize inside a scrolled container" do
  it "does not shrink the target on a no-move drag, and tracks pointer motion" do
    s = pc_screen
    sc = Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 60,
      height: 20, scrollable: true
    box = Crysterm::Widget::Box.new parent: sc, top: 5, left: 2,
      width: 30, height: 8, style: Crysterm::Style.new(border: true)
    grip = Crysterm::Widget::SizeGrip.new parent: box, bottom: 0, right: 0,
      width: 1, height: 1
    Crysterm::Widget::Box.new parent: sc, top: 40, left: 0, width: 4, height: 1
    s.repaint

    k = 3
    sc.scroll_to k, true
    s.repaint

    # Sanity: the target and its grip are painted k rows above their layout row.
    box.lpos.not_nil!.yi.should eq box.atop - k
    g_lp = grip.lpos.not_nil!

    # The grip's painted outer cell (grip is 1x1).
    gx = g_lp.xl - 1
    gy = g_lp.yl - 1

    data = Crysterm::DragData.new(grip)
    session = Crysterm::DragSession.new(grip, data, gx, gy, Crysterm::DragSensor::Mouse)
    grip.emit Crysterm::Event::DragStart, session

    # Drag with the pointer held on the grip (no motion). The target must keep
    # its size — pre-fix it shrank by the scroll offset k (8 -> 5).
    session.x = gx
    session.y = gy
    grip.emit Crysterm::Event::Drag, session
    box.width.should eq 30
    box.height.should eq 8

    # Move the pointer 5 right / 3 down: the outer edge follows by exactly that
    # much (35 / 11), regardless of the scroll offset.
    session.x = gx + 5
    session.y = gy + 3
    grip.emit Crysterm::Event::Drag, session
    box.width.should eq 35
    box.height.should eq 11
  end
end

describe "BUGS17 B17-18: ColorDialog gradient hit-test inside a scrolled container" do
  it "picks a color from the painted field instead of falling through to begin_move" do
    s = pc_screen
    sc = Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 60,
      height: 24, scrollable: true
    cd = Crysterm::Widget::ColorDialog.new parent: sc, top: 5, left: 0,
      width: 56, height: 20
    cd.show
    Crysterm::Widget::Box.new parent: sc, top: 40, left: 0, width: 4, height: 1
    s.repaint

    k = 3
    sc.scroll_to k, true
    s.repaint

    lp = cd.lpos.not_nil!
    # Sanity: painted k rows above the layout row.
    lp.yi.should eq cd.atop - k

    # Default state is fully-saturated (1.0). Click the top-left painted cell of
    # the 2-D field (saturation 0.0). This lands in the first k painted rows,
    # which pre-fix mapped to a negative offset (outside the field) and fell
    # through to begin_move, leaving the color untouched.
    ox = lp.xi + cd.ileft
    oy = lp.yi + cd.itop
    px = ox + Crysterm::Widget::ColorDialog::FIELD_X
    py = oy + Crysterm::Widget::ColorDialog::FIELD_Y + 1

    cd.saturation.should eq 1.0
    cd.emit Crysterm::Event::Mouse, pc_mouse(Tput::Mouse::Action::Down, px, py)

    # Post-fix: the click picks saturation 0.0 from the leftmost field column.
    # Pre-fix: begin_move ran instead and saturation stayed 1.0.
    cd.saturation.should eq 0.0
  end
end
