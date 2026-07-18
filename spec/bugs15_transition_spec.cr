require "./spec_helper"

include Crysterm

# BUGS15 CSS `transition` fixes:
#   #27 in-flight tween not cancelled when the new state's map drops the property
#   #59 a transition declared only in the target state rule never tweens on enter
#   #60 `transition: all` is silently ignored

private def sized_screen(w, h)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h)
end

describe "BUGS15 CSS transition" do
  # #59 — the destination state's `transition` governs the enter animation, even
  # when it is declared only inside the state rule (base style has none).
  it "#59 tweens a transition declared only in the target state rule (enter leg)" do
    s = sized_screen 10, 3
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
    b.add_css_class "b59"
    s.stylesheet = ".b59 { background-color: #000000; } " \
                   ".b59:hover { background-color: #ffffff; transition: background-color 0.2s linear; }"
    s._render
    b.style.bg.should eq 0x000000

    b.state = Crysterm::WidgetState::Hovered
    sleep 0.1.seconds # ~halfway through the 0.2s tween
    mid = b.style.bg.not_nil!
    mid.should_not eq 0xffffff # actually tweening, not snapped instantly
    (0x101010 <= mid <= 0xf0f0f0).should be_true

    sleep 0.25.seconds
    b.style.bg.should eq 0xffffff # landed on target
  end

  # #59 verifier: the EXIT leg is correct CSS and must stay instant — the normal
  # style declares no transition, so leaving the state snaps.
  it "#59 snaps on exit (normal state declares no transition)" do
    s = sized_screen 10, 3
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
    b.add_css_class "b59b"
    s.stylesheet = ".b59b { background-color: #000000; } " \
                   ".b59b:hover { background-color: #ffffff; transition: background-color 0.2s linear; }"
    s._render
    b.state = Crysterm::WidgetState::Hovered
    sleep 0.35.seconds
    b.style.bg.should eq 0xffffff

    b.state = Crysterm::WidgetState::Normal
    b.style.bg.should eq 0x000000 # immediate snap, per CSS
  end

  # #60 — `transition: all` expands to every supported property.
  it "#60 honors `transition: all` (tweens color and opacity)" do
    s = sized_screen 10, 3
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
    b.add_css_class "b60"
    s.stylesheet = ".b60 { background-color: #000000; opacity: 1.0; transition: all 0.2s linear; } " \
                   ".b60:hover { background-color: #ffffff; opacity: 0.0; }"
    s._render

    b.state = Crysterm::WidgetState::Hovered
    sleep 0.1.seconds
    mid = b.style.bg.not_nil!
    mid.should_not eq 0xffffff # bg tweening, not snapped
    (0x101010 <= mid <= 0xf0f0f0).should be_true
    (0.2 <= b.style.opacity.not_nil! <= 0.8).should be_true # opacity tweening too

    sleep 0.25.seconds
    b.style.bg.should eq 0xffffff
    (b.style.opacity.not_nil! < 0.05).should be_true
  end

  # #60 — an explicit per-property entry overrides `all` (and does not double-run
  # the tween); both still animate.
  it "#60 lets an explicit property entry coexist with `all`" do
    s = sized_screen 10, 3
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
    b.add_css_class "b60b"
    s.stylesheet = ".b60b { background-color: #000000; opacity: 1.0; " \
                   "transition: all 0.2s linear, background-color 0.2s linear; } " \
                   ".b60b:hover { background-color: #ffffff; opacity: 0.0; }"
    s._render
    b.state = Crysterm::WidgetState::Hovered
    sleep 0.35.seconds
    b.style.bg.should eq 0xffffff
    (b.style.opacity.not_nil! < 0.05).should be_true
  end

  # #27 — leaving a state whose transition tweened a property must cancel that
  # in-flight tween when the new state's map omits the property, or it keeps
  # writing the OLD target into the NEW state's style.
  it "#27 cancels an in-flight tween the new state's map drops" do
    s = sized_screen 10, 3
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
    b.add_css_class "b27"
    # Normal declares a background-color transition; hover declares a *long*
    # opacity transition. Un-hovering must cancel the opacity tween even though
    # the normal map has no opacity entry.
    s.stylesheet = ".b27 { opacity: 1.0; transition: background-color 0.2s linear; } " \
                   ".b27:hover { opacity: 0.5; transition: opacity 2s linear; }"
    s._render
    b.style.opacity.should eq 1.0

    b.state = Crysterm::WidgetState::Hovered
    sleep 0.15.seconds # opacity tweening 1.0 -> 0.5, still far from done (2s)
    (0.5 < b.style.opacity.not_nil! < 1.0).should be_true

    b.state = Crysterm::WidgetState::Normal
    b.transition_running?.should be_false # tween stopped, not left in flight
    sleep 0.2.seconds
    # Without the fix the orphaned tween keeps writing toward 0.5 into the
    # normal style; with it, normal opacity stays put.
    b.style.opacity.should eq 1.0
  end
end
