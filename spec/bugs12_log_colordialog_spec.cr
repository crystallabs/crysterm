require "./spec_helper"

include Crysterm

# Regression specs for BUGS12 findings 30 and 31.
#
#  Finding 30 (src/widget/log.cr): `Log` wired its `Event::ContentChanged` handler
#     as `def set_content(e)`, whose unrestricted 1-arg signature SHADOWED
#     `Widget#set_content(content = "", ...)`. So `log.content = "x"` (and any
#     1-arg `set_content`) dispatched to the handler — which only calls
#     `request_render` — and never stored the content. The handler is renamed to
#     `on_set_content` so the content API is no longer shadowed.
#
#  Finding 31 (src/widget/color_dialog.cr): the custom window-move drag wrote
#     ABSOLUTE pointer coordinates straight into the parent-RELATIVE `left`/`top`,
#     and captured the grab offset against the margin-inclusive `aleft`/`atop`.
#     The fix subtracts the parent content origin (like `DockWidget#wire_drag`
#     and `Widget#enable_drag`) and grabs against `aleft(with_margin: false)` /
#     `atop(with_margin: false)`.

private def lcd_screen(w = 100, h = 40)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

private def lcd_mouse(action : Tput::Mouse::Action, x : Int32, y : Int32)
  Tput::Mouse::Event.new(action, Tput::Mouse::Button::Left, x, y)
end

describe "BUGS12 finding 30: Log#set_content no longer shadows the content API" do
  it "stores content when assigned via `content=`" do
    s = lcd_screen
    log = Crysterm::Widget::Log.new parent: s, top: 0, left: 0, width: 30, height: 5

    log.content = "hello world"
    # Before the fix this dispatched to the ContentChanged handler (request_render
    # only), leaving @content empty.
    log.content.should eq "hello world"
  end

  it "stores content when set via a 1-arg set_content call" do
    s = lcd_screen
    log = Crysterm::Widget::Log.new parent: s, top: 0, left: 0, width: 30, height: 5

    log.set_content "second"
    log.content.should eq "second"
  end

  it "still re-renders on a ContentChanged event via the renamed handler" do
    s = lcd_screen
    log = Crysterm::Widget::Log.new parent: s, top: 0, left: 0, width: 30, height: 5
    # The renamed handler is what ContentChanged is wired to; invoking it directly
    # must not raise and must be a plain (event-arg) method, distinct from the
    # content setter.
    log.on_set_content(Crysterm::Event::ContentChanged.new).should be_nil
  end
end

describe "BUGS12 finding 31: ColorDialog window-move uses parent-relative coords" do
  it "moves by the pointer delta in parent-relative left/top, not absolute" do
    s = lcd_screen
    # A parent with a non-zero content origin so absolute-vs-relative differ.
    parent = Crysterm::Widget::Box.new(
      parent: s, left: 10, top: 5, width: 80, height: 30)
    cd = Crysterm::Widget::ColorDialog.new(
      parent: parent, top: 2, left: 2, width: 56, height: 20)
    cd.show
    s._render

    cd.left.should eq 2
    cd.top.should eq 2

    px = parent.aleft + parent.ileft
    py = parent.atop + parent.itop
    px.should be > 0
    py.should be > 0

    # Grab the empty gap column between the saturation field and the hue bar
    # (not the field, hue, palette, or buttons), which starts a window move.
    ox = cd.aleft + cd.ileft
    oy = cd.atop + cd.itop
    gx = ox + Crysterm::Widget::ColorDialog::FIELD_W
    gy = oy
    cd.emit Crysterm::Event::Mouse, lcd_mouse(Tput::Mouse::Action::Down, gx, gy)

    # Drag three cells right and one cell down. The move handler was installed on
    # the window, so drive it there.
    s.emit Crysterm::Event::Mouse, lcd_mouse(Tput::Mouse::Action::Move, gx + 3, gy + 1)

    # The dialog must follow by exactly the pointer delta in parent-relative
    # space: 2 -> 5 and 2 -> 3. Before the fix `left`/`top` absorbed the parent
    # content origin (px/py), landing at ~15 / ~8 instead.
    cd.left.should eq 5
    cd.top.should eq 3
  end
end
