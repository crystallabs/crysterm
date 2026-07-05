require "./spec_helper"

include Crysterm

# Regression spec: `Media::Base#@load_failed` must be cleared on a *new* file
# load, matching its own documented contract ("Reset on new file load").
#
# `#source` early-returns `nil` whenever `@load_failed` is set (so a failed
# decode / stream-open isn't retried on every render). It was cleared in
# `bitmap=` and `clear_image`, but NOT in either concrete `#load`
# (`Media::Cells#load` / `Media::Graphics#load`). Consequence before the fix:
# once ANY load failed, every subsequent `load(valid_file)` still saw the stale
# latch and `#source` returned `nil` immediately — the widget stayed stuck on
# "could not load" even for a perfectly good new file.

private def hl_window(w = 20, h = 10)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h)
end

describe "Media#load clears the @load_failed latch (state-reset bug)" do
  it "recovers on a valid load after a prior failed load (Cells backend)" do
    s = hl_window
    img = Crysterm::Widget::Media::Ansi.new parent: s, top: 0, left: 0, width: 8, height: 4

    # First load fails: latches @load_failed, content shows the error.
    img.load "/nonexistent/definitely-not-here.png"
    img.content.should contain("Media Error")

    # A subsequent valid load must actually be attempted (latch cleared), so the
    # error content is gone. Before the fix `#source` short-circuited on the
    # stale latch and the error persisted.
    img.load "data/image/matterhorn.png"
    img.content.should_not contain("Media Error")
  ensure
    s.try &.destroy
  end
end
