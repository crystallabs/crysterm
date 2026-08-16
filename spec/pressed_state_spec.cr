require "./spec_helper"

include Crysterm

# The Qt `:pressed` state and its QSS press-in idiom: a held-down
# `AbstractButton` takes `WidgetState::Selected` (so `:pressed`/`:active` rules
# apply), and a state rule's `top`/`left`/`right`/`bottom` act as a relative
# positional nudge of the rendered box (`QPushButton:pressed { top: 1px;
# left: 1px }`) rather than widget geometry.

describe "Button pressed state" do
  it "is down with the Selected state while the mouse is held, restoring focus on release" do
    s = headless_screen(20, 5)
    b = Widget::Button.new parent: s, top: 1, left: 2, width: 6, height: 1, text: "OK"
    s.repaint

    b.down?.should be_false
    s.dispatch_mouse ::Tput::Mouse::Event.new(::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left, b.aleft, b.atop)
    b.down?.should be_true
    # Click-to-focus ran mid-press; the pressed state must survive it.
    b.focused?.should be_true
    b.state.selected?.should be_true

    s.dispatch_mouse ::Tput::Mouse::Event.new(::Tput::Mouse::Action::Up, ::Tput::Mouse::Button::Left, b.aleft, b.atop)
    b.down?.should be_false
    b.state.focused?.should be_true
  end

  it "sees the release even when it lands off-widget (mouse grab)" do
    s = headless_screen(20, 5)
    b = Widget::Button.new parent: s, top: 1, left: 2, width: 6, height: 1, text: "OK"
    s.repaint

    s.dispatch_mouse ::Tput::Mouse::Event.new(::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left, b.aleft, b.atop)
    b.down?.should be_true
    s.dispatch_mouse ::Tput::Mouse::Event.new(::Tput::Mouse::Action::Up, ::Tput::Mouse::Button::Left, 0, 0)
    b.down?.should be_false
  end

  it "applies :pressed CSS colors while down" do
    s = headless_screen(20, 5)
    b = Widget::Button.new parent: s, top: 1, left: 2, width: 6, height: 1, text: "OK"
    s.stylesheet = "Button { background-color: #001122; } Button:pressed { background-color: #ff0000; }"
    s.repaint
    b.style.bg.should eq 0x001122

    s.dispatch_mouse ::Tput::Mouse::Event.new(::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left, b.aleft, b.atop)
    b.style.bg.should eq 0xff0000
    s.dispatch_mouse ::Tput::Mouse::Event.new(::Tput::Mouse::Action::Up, ::Tput::Mouse::Button::Left, b.aleft, b.atop)
    b.style.bg.should eq 0x001122
  end

  it "flashes the pressed look around a keyboard activation" do
    s = headless_screen(20, 5)
    b = Widget::Button.new parent: s, top: 1, left: 2, width: 6, height: 1, text: "OK"
    s.repaint

    clicked = 0
    b.on_clicked { clicked += 1 }
    b.emit Crysterm::Event::KeyPress.new(' ')
    clicked.should eq 1
    b.down?.should be_true # the animate-click flash
    wait_until { !b.down? }
    b.state.selected?.should be_false
  end

  it "still emits Event::Click on a mouse press" do
    s = headless_screen(20, 5)
    b = Widget::Button.new parent: s, top: 1, left: 2, width: 6, height: 1, text: "OK"
    s.repaint

    clicked = 0
    b.on_clicked { clicked += 1 }
    s.dispatch_mouse ::Tput::Mouse::Event.new(::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left, b.aleft, b.atop)
    clicked.should eq 1
  end
end

describe "QSS :pressed positional offset" do
  it "nudges the rendered box (press-in) while pressed, restoring on release" do
    s = headless_screen(20, 6)
    b = Widget::Button.new parent: s, top: 1, left: 2, width: 6, height: 1, text: "OK"
    s.stylesheet = "Button:pressed { top: 1; left: 1; }"
    s.repaint

    lp = b.lpos.not_nil!
    x0 = lp.xi
    y0 = lp.yi

    b.state = :selected
    s.repaint
    lp = b.lpos.not_nil!
    lp.xi.should eq x0 + 1
    lp.yi.should eq y0 + 1

    b.state = :normal
    s.repaint
    lp = b.lpos.not_nil!
    lp.xi.should eq x0
    lp.yi.should eq y0
  end

  it "keeps the widget's own geometry specs untouched by a state offset" do
    s = headless_screen(20, 6)
    b = Widget::Button.new parent: s, top: 1, left: 2, width: 6, height: 1, text: "OK"
    s.stylesheet = "Button:pressed { top: 1; left: 1; }"
    s.repaint
    b.state = :selected
    s.repaint
    b.top.should eq 1
    b.left.should eq 2
    b.styles.normal.offset?.should be_false
  end

  it "treats normal-state top/left as absolute geometry, not an offset" do
    s = headless_screen(20, 6)
    b = Widget::Button.new parent: s, width: 6, height: 1, text: "OK"
    s.stylesheet = "Button { top: 3; left: 4; }"
    s.repaint
    b.top.should eq 3
    b.left.should eq 4
    b.styles.normal.offset?.should be_false
  end

  it "resolves offset values with Qt's semantics" do
    st = Style.new
    # `right`/`bottom` are the negated `left`/`top` (Qt: `bottom: y` ≡ `top: -y`).
    Crysterm::CSS::Geometry.apply_offset(st, "right", "2")
    Crysterm::CSS::Geometry.apply_offset(st, "bottom", "1")
    st.offset_x.should eq -2
    st.offset_y.should eq -1
    # An explicit `left`/`top` wins over `right`/`bottom`.
    Crysterm::CSS::Geometry.apply_offset(st, "left", "3")
    st.offset_x.should eq 3
    # The classic sub-cell QSS nudge (`top: 1px`) rounds away from zero to a
    # visible one-cell nudge instead of silently to 0.
    Crysterm::CSS::Geometry.apply_offset(st, "top", "1px")
    st.offset_y.should eq 1
    # Non-length forms have no offset meaning and are dropped.
    st2 = Style.new
    Crysterm::CSS::Geometry.apply_offset(st2, "top", "50%")
    st2.offset?.should be_false
  end

  it "translates the QSS spelling through to native :pressed" do
    css = Crysterm::CSS::Qss.to_css("QPushButton:pressed { top: 1px; left: 1px; }")
    css.should contain "Button:pressed"
    css.should contain "top: 1px"
  end
end

describe "click flash via CSS transition" do
  it "snaps red on press and fades back over the declared duration on release" do
    s = headless_screen(20, 5)
    b = Widget::Button.new parent: s, top: 1, left: 2, width: 6, height: 1, text: "OK"
    s.stylesheet = "Button { background-color: #000000; transition: background-color 0.2s linear; } " \
                   "Button:pressed { background-color: #ff0000; transition: none; }"
    s.repaint
    b.style.bg.should eq 0x000000

    # Press: the pressed rule overrides the transition (`none`), so the flash
    # color lands instantly.
    s.dispatch_mouse ::Tput::Mouse::Event.new(::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left, b.aleft, b.atop)
    b.style.bg.should eq 0xff0000

    # Release: the base transition tweens the red back out.
    s.dispatch_mouse ::Tput::Mouse::Event.new(::Tput::Mouse::Action::Up, ::Tput::Mouse::Button::Left, b.aleft, b.atop)
    sleep 0.1.seconds # ~halfway through the 0.2s linear fade
    mid = b.style.bg.not_nil!
    (mid > 0x200000).should be_true # still visibly red-tinted
    (mid < 0xff0000).should be_true # but no longer full red

    wait_until { b.style.bg == 0x000000 }
    b.style.bg.should eq 0x000000
  end
end
