require "./spec_helper"

include Crysterm

# FORMAL-WIDGETS Part B / B8 — shared behavioral conformance for the ranged
# widget family (`Slider`, `Dial`, `ScrollBar`, `ProgressBar`). A single
# interaction script is driven against every member through a tiny adapter, so an
# invariant that *should* hold family-wide is proven family-wide instead of hoped.
# Deliberate differences are encoded as adapter capability flags (e.g. only the
# `AbstractSlider` trio has Home/End and the wheel), so an *accidental* divergence
# fails here. Would have caught the live B0.2 (inverted range) / B0.3 (missing
# vi-keys) drift the family already suffered.

private def mem_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

private def kp(char : Char, key : ::Tput::Key? = nil)
  Crysterm::Event::KeyPress.new char, key
end

private def wheel_event(down : Bool)
  act = down ? ::Tput::Mouse::Action::WheelDown : ::Tput::Mouse::Action::WheelUp
  Crysterm::Event::Mouse.new(::Tput::Mouse::Event.new(act, ::Tput::Mouse::Button::None, 0, 0, source: :test))
end

# One family member's adapter. `build` makes a fresh widget with a given
# (min, max, value); the accessors and gestures operate on that widget. `home_end`
# and `wheel` mark the capabilities only the `AbstractSlider` trio has.
private record RangedCase,
  name : String,
  build : Proc(Crysterm::Window, Int32, Int32, Int32, Crysterm::Widget),
  value : Proc(Crysterm::Widget, Int32),
  set_value : Proc(Crysterm::Widget, Int32, Nil),
  minimum : Proc(Crysterm::Widget, Int32),
  maximum : Proc(Crysterm::Widget, Int32),
  send_key : Proc(Crysterm::Widget, Char, ::Tput::Key?, Nil),
  home_end : Bool,
  wheel : Proc(Crysterm::Widget, Bool, Nil)?

private def it_behaves_like_a_ranged_widget(c : RangedCase)
  describe c.name do
    it "clamps the value into [minimum, maximum]" do
      s = mem_screen
      w = c.build.call s, 0, 10, 5
      c.set_value.call w, 999
      c.value.call(w).should eq 10
      c.set_value.call w, -999
      c.value.call(w).should eq 0
    end

    it "never stores an inverted range (max below min collapses to min)" do
      s = mem_screen
      w = c.build.call s, 100, 0, 50
      (c.minimum.call(w) <= c.maximum.call(w)).should be_true
    end

    it "emits Event::ValueChange once on a real change and not on a no-op" do
      s = mem_screen
      w = c.build.call s, 0, 100, 50
      changes = 0
      w.on(Crysterm::Event::ValueChange) { changes += 1 }
      c.set_value.call w, 40
      changes.should eq 1
      c.set_value.call w, 40 # no-op — must not re-emit
      changes.should eq 1
    end

    it "steps down on 'h' and up on 'l', round-tripping to the start" do
      s = mem_screen
      w = c.build.call s, 0, 100, 50
      v0 = c.value.call w
      c.send_key.call w, 'l', nil
      (c.value.call(w) > v0).should be_true
      c.send_key.call w, 'h', nil
      c.value.call(w).should eq v0
    end

    if c.home_end
      it "jumps to minimum on Home and maximum on End" do
        s = mem_screen
        w = c.build.call s, 0, 100, 50
        c.send_key.call w, '\0', ::Tput::Key::Home
        c.value.call(w).should eq 0
        c.send_key.call w, '\0', ::Tput::Key::End
        c.value.call(w).should eq 100
      end
    end

    if wheel = c.wheel
      it "moves on the wheel and reverses back" do
        s = mem_screen
        w = c.build.call s, 0, 100, 50
        v0 = c.value.call w
        wheel.call w, false # one notch
        (c.value.call(w) != v0).should be_true
        wheel.call w, true # opposite notch
        c.value.call(w).should eq v0
      end
    end
  end
end

describe "Ranged widget conformance (B8)" do
  it_behaves_like_a_ranged_widget RangedCase.new(
    name: "Slider",
    build: ->(s : Crysterm::Window, mn : Int32, mx : Int32, v : Int32) {
      Crysterm::Widget::Slider.new(parent: s, minimum: mn, maximum: mx, value: v, width: 20, height: 1).as(Crysterm::Widget)
    },
    value: ->(w : Crysterm::Widget) { w.as(Crysterm::Widget::Slider).value },
    set_value: ->(w : Crysterm::Widget, v : Int32) { w.as(Crysterm::Widget::Slider).value = v; nil },
    minimum: ->(w : Crysterm::Widget) { w.as(Crysterm::Widget::Slider).minimum },
    maximum: ->(w : Crysterm::Widget) { w.as(Crysterm::Widget::Slider).maximum },
    send_key: ->(w : Crysterm::Widget, ch : Char, k : ::Tput::Key?) { w.as(Crysterm::Widget::Slider).on_keypress kp(ch, k); nil },
    home_end: true,
    wheel: ->(w : Crysterm::Widget, down : Bool) { w.as(Crysterm::Widget::Slider).ranged_wheel wheel_event(down); nil },
  )

  it_behaves_like_a_ranged_widget RangedCase.new(
    name: "Dial",
    build: ->(s : Crysterm::Window, mn : Int32, mx : Int32, v : Int32) {
      Crysterm::Widget::Dial.new(parent: s, minimum: mn, maximum: mx, value: v, width: 10, height: 3).as(Crysterm::Widget)
    },
    value: ->(w : Crysterm::Widget) { w.as(Crysterm::Widget::Dial).value },
    set_value: ->(w : Crysterm::Widget, v : Int32) { w.as(Crysterm::Widget::Dial).value = v; nil },
    minimum: ->(w : Crysterm::Widget) { w.as(Crysterm::Widget::Dial).minimum },
    maximum: ->(w : Crysterm::Widget) { w.as(Crysterm::Widget::Dial).maximum },
    send_key: ->(w : Crysterm::Widget, ch : Char, k : ::Tput::Key?) { w.as(Crysterm::Widget::Dial).on_keypress kp(ch, k); nil },
    home_end: true,
    wheel: ->(w : Crysterm::Widget, down : Bool) { w.as(Crysterm::Widget::Dial).ranged_wheel wheel_event(down); nil },
  )

  it_behaves_like_a_ranged_widget RangedCase.new(
    name: "ScrollBar",
    build: ->(s : Crysterm::Window, mn : Int32, mx : Int32, v : Int32) {
      Crysterm::Widget::ScrollBar.new(parent: s, minimum: mn, maximum: mx, value: v, height: 10).as(Crysterm::Widget)
    },
    value: ->(w : Crysterm::Widget) { w.as(Crysterm::Widget::ScrollBar).value },
    set_value: ->(w : Crysterm::Widget, v : Int32) { w.as(Crysterm::Widget::ScrollBar).value = v; nil },
    minimum: ->(w : Crysterm::Widget) { w.as(Crysterm::Widget::ScrollBar).minimum },
    maximum: ->(w : Crysterm::Widget) { w.as(Crysterm::Widget::ScrollBar).maximum },
    send_key: ->(w : Crysterm::Widget, ch : Char, k : ::Tput::Key?) { w.as(Crysterm::Widget::ScrollBar).on_keypress kp(ch, k); nil },
    home_end: true,
    wheel: ->(w : Crysterm::Widget, down : Bool) { w.as(Crysterm::Widget::ScrollBar).ranged_wheel wheel_event(down), invert: true; nil },
  )

  it_behaves_like_a_ranged_widget RangedCase.new(
    name: "ProgressBar",
    build: ->(s : Crysterm::Window, mn : Int32, mx : Int32, v : Int32) {
      Crysterm::Widget::ProgressBar.new(parent: s, minimum: mn, maximum: mx, value: v, width: 20, height: 1).as(Crysterm::Widget)
    },
    value: ->(w : Crysterm::Widget) { w.as(Crysterm::Widget::ProgressBar).value },
    set_value: ->(w : Crysterm::Widget, v : Int32) { w.as(Crysterm::Widget::ProgressBar).value = v; nil },
    minimum: ->(w : Crysterm::Widget) { w.as(Crysterm::Widget::ProgressBar).minimum },
    maximum: ->(w : Crysterm::Widget) { w.as(Crysterm::Widget::ProgressBar).maximum },
    send_key: ->(w : Crysterm::Widget, ch : Char, k : ::Tput::Key?) { w.as(Crysterm::Widget::ProgressBar).on_keypress kp(ch, k); nil },
    home_end: false, # QProgressBar isn't a QAbstractSlider — no Home/End/PageUp/wheel
    wheel: nil,
  )
end
