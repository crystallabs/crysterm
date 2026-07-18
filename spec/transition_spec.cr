require "./spec_helper"

include Crysterm

# Step 7 (b): declarative CSS `transition`. When an animatable property's value
# changes on a state transition, it is tweened in over its duration rather than
# snapping. Generic — driven entirely from CSS, no widget-specific code.

private def sized_screen(w, h)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h)
end

describe "CSS transition" do
  it "tweens background-color on a :hover state change" do
    s = sized_screen 10, 3
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
    b.add_css_class "btn"
    s.stylesheet = ".btn { background-color: #000000; transition: background-color 0.2s linear; } " \
                   ".btn:hover { background-color: #ffffff; }"
    s._render
    b.style.bg.should eq 0x000000

    b.state = Crysterm::WidgetState::Hovered
    sleep 0.1.seconds # ~halfway through the 0.2s linear tween
    mid = b.style.bg.not_nil!
    (0x202020 <= mid <= 0xe0e0e0).should be_true # mid-transition grey, not yet white

    sleep 0.2.seconds
    b.style.bg.should eq 0xffffff # landed on target
  end

  it "tweens opacity on a state change" do
    s = sized_screen 10, 3
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
    b.add_css_class "x"
    s.stylesheet = ".x { opacity: 1.0; transition: opacity 0.2s linear; } .x:hover { opacity: 0.0; }"
    s._render

    b.state = Crysterm::WidgetState::Hovered
    sleep 0.1.seconds
    (0.2 <= b.style.opacity.not_nil! <= 0.8).should be_true # mid-fade

    sleep 0.2.seconds
    (b.style.opacity.not_nil! < 0.05).should be_true # ~fully faded
  end

  it "snaps (no tween) when no transition is declared" do
    s = sized_screen 10, 3
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
    b.add_css_class "y"
    s.stylesheet = ".y { background-color: #000000; } .y:hover { background-color: #ffffff; }"
    s._render
    b.state = Crysterm::WidgetState::Hovered
    b.style.bg.should eq 0xffffff # immediate, no animation
  end
end

describe "CSS @keyframes / animation" do
  it "plays a looping keyframe animation, interpolating between stops" do
    s = sized_screen 10, 3
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
    b.add_css_class "glow"
    s.stylesheet = "@keyframes glow { from { background-color: #000000; } to { background-color: #ffffff; } } " \
                   ".glow { background-color: #000000; animation: glow 0.2s linear infinite; }"
    s._render # starts the animation
    sleep 0.1.seconds
    mid = b.style.bg.not_nil!
    (0x303030 <= mid <= 0xd0d0d0).should be_true # interpolating between black and white
  end

  it "settles on the final frame for a finite (1-iteration) animation" do
    s = sized_screen 10, 3
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
    b.add_css_class "once"
    s.stylesheet = "@keyframes go { from { opacity: 0.0; } to { opacity: 1.0; } } " \
                   ".once { opacity: 0.0; animation: go 0.15s linear 1; }"
    s._render
    sleep 0.3.seconds                                # past the single iteration
    (b.style.opacity.not_nil! > 0.95).should be_true # landed on the final frame
  end

  # CSS property names are case-insensitive, so a `transition` value naming the
  # animated property in mixed case (`Background-Color`) must be folded to the
  # lower-cased key the tween driver matches on; otherwise it silently never
  # tweens.
  it "folds the animated property name (case-insensitive)" do
    st = Style.new
    Crysterm::CSS::Properties.apply(st, "transition", "Background-Color 0.3s linear")
    trans = st.transitions.not_nil!
    trans.has_key?("background-color").should be_true
    trans.has_key?("Background-Color").should be_false
  end
end
