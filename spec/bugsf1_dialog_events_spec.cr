require "./spec_helper"

include Crysterm

# Regression specs for BUGS-F1 findings owned by the dialog/geometry files:
#
#  Finding 6  (src/widget/color_dialog.cr): `on_mouse` guarded on the bare
#     `@ev_move` Subscription (always truthy), so ALL direct field/hue mouse
#     input was dead. Now guards on `@ev_move.active?`.
#
#  Finding 17 (src/widget/dialog.cr + color_dialog.cr): the window-level
#     Enter/Escape accelerator double-fired when a focused dialog button already
#     consumed the key (Cancel focused + Enter → BOTH Rejected AND Accepted).
#     `Dialog#dialog_key` now returns early on `e.accepted?`, so the accelerator
#     stands down once the focused button has consumed the key.
#
#  Finding 16 (src/widget/question.cr): `Question#ask`'s window-level KeyPress
#     handler fired alongside the buttons' Press handlers with no idempotence,
#     so Enter on a focused button invoked the user callback twice. `done` now
#     has a `done_called` latch and the key handler bails on `e.accepted?`.
#
#  Finding 15 (src/widget_size.cr + widget_position.cr): geometry setters emitted
#     Resize/Move BEFORE assigning the new ivar, so in-tree listeners recomputed
#     against the OLD value. Setters now assign first, then emit.

private def f1_screen
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: 24, default_quit_keys: false)
end

private def enter_key
  Crysterm::Event::KeyPress.new '\r', ::Tput::Key::Enter
end

private def mouse_down(x : Int32, y : Int32)
  Tput::Mouse::Event.new(Tput::Mouse::Action::Down, Tput::Mouse::Button::Left, x, y)
end

# Recursively find the first descendant button whose content includes *label*.
private def find_button(w : Crysterm::Widget, label : String) : Crysterm::Widget::Button
  w.children.each do |c|
    if c.is_a?(Crysterm::Widget::Button) && c.content.to_s.downcase.includes?(label)
      return c
    end
    if found = find_button?(c, label)
      return found
    end
  end
  raise "no button matching #{label.inspect}"
end

private def find_button?(w : Crysterm::Widget, label : String) : Crysterm::Widget::Button?
  w.children.each do |c|
    if c.is_a?(Crysterm::Widget::Button) && c.content.to_s.downcase.includes?(label)
      return c
    end
    if found = find_button?(c, label)
      return found
    end
  end
  nil
end

# ---------------------------------------------------------------- Finding 6
describe "BUGS-F1 finding 6: ColorDialog direct mouse input is not dead" do
  it "a mouse-down in the saturation/value field updates saturation and value" do
    s = f1_screen
    cd = Crysterm::Widget::ColorDialog.new parent: s, top: 0, left: 0, width: 56, height: 20
    cd.show
    # Hit-testing / geometry uses the painted lpos, so render once first.
    s.repaint

    # Start from a known corner color so a mid-field click must move it.
    cd.current_color = "#ffffff"
    cd.saturation.should eq 0.0 # white == fully desaturated
    cd.hsv_value.should eq 1.0

    # Field origin, computed the same way `on_mouse` does.
    ox = cd.aleft + cd.ileft
    oy = cd.atop + cd.itop
    # A point in the middle of the FIELD_W x FIELD_H gradient.
    fx = ox + Crysterm::Widget::ColorDialog::FIELD_X + 12
    fy = oy + Crysterm::Widget::ColorDialog::FIELD_Y + 5

    cd.emit Crysterm::Event::Mouse, mouse_down(fx, fy)

    # With the `@ev_move.active?` fix the handler runs and sets S from X, V from Y.
    cd.saturation.should be > 0.0
    cd.hsv_value.should be < 1.0
  end
end

# --------------------------------------------------------------- Finding 17
describe "BUGS-F1 finding 17: ColorDialog Enter with a focused button fires once" do
  it "emits exactly one of Accepted/Rejected when Cancel is focused and Enter pressed" do
    s = f1_screen
    cd = Crysterm::Widget::ColorDialog.new parent: s, top: 0, left: 0, width: 56, height: 20

    accepted = 0
    rejected = 0
    cd.on(Crysterm::Event::Accepted) { accepted += 1 }
    cd.on(Crysterm::Event::Rejected) { rejected += 1 }

    cd.get_color { }
    s.repaint

    # Focus the Cancel button so it consumes/accepts the Enter itself.
    cancel = find_button cd, "cancel"
    cancel.focus

    s.emit enter_key

    # Before the fix BOTH the button's Rejected AND the accelerator's Accepted
    # fired (total 2). Now the accelerator stands down on `e.accepted?`, so
    # exactly one signal is emitted.
    (accepted + rejected).should eq 1
  end
end

# --------------------------------------------------------------- Finding 16
describe "BUGS-F1 finding 16: Question callback fires once on Enter over a focused button" do
  it "invokes the user callback exactly once" do
    s = f1_screen
    q = Crysterm::Widget::Question.new parent: s, top: 0, left: 0, width: 40, height: 8

    count = 0
    q.ask("Sure?") { |_data| count += 1 }
    s.repaint

    # Focus the Ok button; its Enter → Press → done, and the window-level key
    # handler also saw Enter. Before the fix both paths invoked the callback.
    ok = find_button q, "ok"
    ok.focus

    s.emit enter_key

    count.should eq 1
  end
end

# --------------------------------------------------------------- Finding 15
describe "BUGS-F1 finding 15: geometry setters assign before emitting" do
  it "width= : a Resize listener sees the NEW width" do
    s = f1_screen
    box = Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 4
    seen = nil.as(Int32 | String?)
    box.on(Crysterm::Event::Resize) { seen = box.width }
    box.width = 25
    seen.should eq 25
  end

  it "height= : a Resize listener sees the NEW height" do
    s = f1_screen
    box = Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 4
    seen = nil.as(Int32 | String?)
    box.on(Crysterm::Event::Resize) { seen = box.height }
    box.height = 9
    seen.should eq 9
  end

  it "min_width= : a Resize listener sees the NEW min_width" do
    s = f1_screen
    box = Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 4
    seen = nil.as(Int32?)
    box.on(Crysterm::Event::Resize) { seen = box.min_width }
    box.min_width = 5
    seen.should eq 5
  end

  it "left= : a Move listener sees the NEW left" do
    s = f1_screen
    box = Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 4
    seen = nil.as(Int32 | String?)
    box.on(Crysterm::Event::Move) { seen = box.left }
    box.left = 7
    seen.should eq 7
  end

  it "top= : a Move listener sees the NEW top" do
    s = f1_screen
    box = Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 4
    seen = nil.as(Int32 | String?)
    box.on(Crysterm::Event::Move) { seen = box.top }
    box.top = 3
    seen.should eq 3
  end
end
