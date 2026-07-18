require "./spec_helper"

include Crysterm

# Opacity fades (`widget_fade.cr`). `fade_out` ends by hiding the widget; it must
# not leave `style.opacity` pinned at 0.0, or a *later* plain `#show` would repaint
# the widget fully transparent (i.e. silently invisible).

private def sized_screen(w, h)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h)
end

private def wait_until(timeout = 2.seconds, &)
  deadline = Time.instant + timeout
  until yield
    raise "condition not met within #{timeout}" if Time.instant > deadline
    sleep 5.milliseconds
  end
end

describe "Widget#fade_out" do
  it "hides the widget and clears the residual opacity so a later #show is opaque" do
    s = sized_screen 10, 3
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
    b.fade_out 0.05.seconds
    # `hide` runs in the tween's on-stop callback (after `running?` already
    # flipped false), so wait on the visible side effect, not on `running?`.
    wait_until { !b.visible? }

    b.visible?.should be_false
    # No residual transparency left behind by the tween's final (opacity == 0) tick.
    b.style.opacity?.should be_nil

    # A plain show must make it actually visible again, not paint nothing.
    b.show
    b.visible?.should be_true
    b.style.opacity?.should be_nil
  end
end
