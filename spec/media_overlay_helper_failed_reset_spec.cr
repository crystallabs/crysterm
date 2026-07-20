require "./spec_helper"

include Crysterm

# Regression spec (same class as the `@load_failed` latch bug): `Media::Overlay`
# latches `@helper_failed` when the external `w3mimgdisplay` helper fails in
# `#redraw_image`, and short-circuits every later redraw on it. It was cleared in
# `#clear_image` but NOT in `#load`, so once the helper failed once, a subsequent
# `load(good_file)` stayed permanently un-drawn — exactly the defect its own
# sibling `Media::Tek#load` avoids by resetting `@decode_failed` (see
# `bugsf1_media_spec.cr` Finding 19). The codebase explicitly parallels the two
# flags.

private def hl_window(w = 20, h = 10)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h)
end

describe "Media::Overlay#load clears the @helper_failed latch" do
  it "resets helper_failed on a new load so the helper is retried" do
    s = hl_window
    img = Crysterm::Widget::Media::Overlay.new(
      file: "/nonexistent/typo-#{Process.pid}.png",
      parent: s, top: 0, left: 0, width: 8, height: 4)

    img.helper_failed?.should be_false

    # Drive the real post-render hook: `redraw_image` runs and (with no working
    # `w3mimgdisplay`) latches `@helper_failed`. Must not raise out of render.
    s.repaint

    # Only meaningful when the helper actually failed here (i.e. w3mimgdisplay
    # absent / erroring, the common CI case). If it happened to succeed, the
    # reset-on-load logic still holds but this environment can't exercise it.
    pending! "w3mimgdisplay available — could not reproduce a helper failure" unless img.helper_failed?

    # The bug: a new load must clear the latch so the helper is retried.
    img.load "data/image/matterhorn.png"
    img.helper_failed?.should be_false
  ensure
    s.try &.destroy
  end
end
