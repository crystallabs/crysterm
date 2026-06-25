# FEATURED ANIMATION: the classic Netscape throbber, shown two ways at once —
#
#   left  — the animation at a FIXED size
#   right — the SAME animation while its box is RESIZED every frame
#
# It demonstrates that every image backend now ANIMATES *and* resizes: each
# shown frame is sampled to the current box (lazily, cached per size).
#
# The BACKEND env var picks the renderer; all of these animate:
#   glyph (default) — sub-cell Unicode glyphs (octant: 2x4 sub-pixels per cell),
#                     ~8x the resolution of plain cells and capturable anywhere
#   kitty | sixel | iterm — true-pixel terminal graphics (needs a capable
#                     terminal: kitty/WezTerm/Konsole, an xterm -ti vt340, …)
#   ansi            — one cell per pixel (lowest resolution)
#
# Load a different image with IMAGE=… .

require "../../src/crysterm"

include Crysterm

img_path = ENV["IMAGE"]? || "#{__DIR__}/../../data/image/netscape.gif"
name = File.basename(img_path)

# Pick the rendering backend; all of these animate and resize.
def make_image(backend, **opts)
  case backend
  when "kitty" then Widget::Media::Kitty.new(**opts)
  when "sixel" then Widget::Media::Sixel.new(**opts)
  when "iterm" then Widget::Media::Iterm.new(**opts)
  when "ansi"  then Widget::Media::Ansi.new(**opts)
  else              Widget::Media::Glyph.new(**opts, mode: Widget::Media::Glyph::Mode::Octant)
  end
end

backend = ENV["BACKEND"]? || "glyph"

# The source animation's per-frame delays (ms). When recording, one fiber drives
# both throbbers and the resize box off this single frame clock (see below) so
# the whole scene has an exact period of `frame_delays.size` frames and the GIF
# captured marker-to-marker tiles seamlessly — it looks like it runs forever.
frame_delays = begin
  fr = PNGGIF::PNG.new(img_path).frames
  fr && !fr.empty? ? fr.map(&.delay) : [100]
end
frame_count = frame_delays.size

s = Screen.new title: "Netscape"

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}#{name}  ·  #{backend} graphics  ·  left: fixed size   ·   right: resizing while it plays{/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#202830")

ih = s.aheight - 1
half = s.awidth // 2

# Left: the animation at a fixed size.
left = make_image backend,
  parent: s, top: 1, left: 0, width: half, height: ih,
  fit: Widget::Media::Fit::Contain, file: img_path,
  style: Style.new(border: true)

# Right: the same animation in a box we resize on every frame.
right = make_image backend,
  parent: s, top: 1, left: half, width: s.awidth - half, height: ih,
  fit: Widget::Media::Fit::Contain, file: img_path,
  style: Style.new(border: true)

rmaxw = s.awidth - half

# Wobble the right box's size from the animation frame index, so one full
# grow/shrink lines up with one throbber loop.
resize_right = ->(idx : Int32) do
  f = idx.to_f / frame_count        # 0 → 1 over a loop
  f = f < 0.5 ? f * 2 : 2.0 - f * 2 # triangle: 0 → 1 → 0
  right.width = (12 + (rmaxw - 12) * f).to_i
  right.height = (5 + (ih - 5) * f).to_i
end

# A single clock for the whole scene. Each Media widget normally animates in its
# own fiber, but those run at slightly different per-frame cost (the resizing box
# re-samples every frame) so they drift apart and the scene never has an exact
# period. Instead, once both have composited their frames, we pause them and
# advance every animated element — both throbbers and the resize — from this one
# frame index. The scene then repeats exactly every `frame_count` frames.
#
# When recording (TTYGIF_MARK, set by make-gifs.sh), each frame is tagged with a
# capture marker (see the loop body) so the recorder can grab exactly one loop
# and the resulting GIF tiles seamlessly.
spawn do
  ready = ->(w : Widget) { w.responds_to?(:frames_ready?) ? w.frames_ready? : true }
  show = ->(w : Widget, i : Int32) { w.anim_index = i if w.responds_to?(:anim_index=) }

  until ready.call(left) && ready.call(right)
    sleep 0.02.seconds
  end
  left.pause if left.responds_to?(:pause)
  right.pause if right.responds_to?(:pause)

  # One shared `Animation` clock drives the whole scene. A single frame index
  # `idx` is written into BOTH throbbers and the resize each tick, so they stay
  # in exact lockstep (a per-widget clock would drift, since the resizing box
  # re-samples every frame at a different cost). The clock honors each frame's
  # own GIF delay via `clock.interval=`, so playback keeps its native timing and
  # the scene repeats precisely every `frame_count` frames.
  mark = ENV["TTYGIF_MARK"]?
  idx = 0
  Crysterm::Animation.new(frame_delays[0].milliseconds) do |clock|
    # Tag every frame with an out-of-band marker (an APC string terminals ignore)
    # carrying its index and source delay, emitted just before the frame is
    # drawn. The recorder uses these to grab exactly one loop, one output frame
    # per source frame at its true boundary (so it tiles seamlessly) and timed by
    # the source delay (so playback is smooth, free of capture jitter).
    if mark
      s.output.print "\e_TTYGIF#{idx},#{frame_delays[idx]}\e\\"
      s.output.flush
    end
    show.call left, idx
    show.call right, idx
    resize_right.call idx
    s.render
    clock.interval = frame_delays[idx].milliseconds # sleep the shown frame's delay
    idx += 1
    idx = 0 if idx >= frame_count
  end.start
end

s.render
s.exec
