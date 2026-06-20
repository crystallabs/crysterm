require "../src/crysterm"

# Port of Blessed's test/widget-image.js
#
# Demonstrates `Widget::Image`, the image factory. With `type: Overlay` it
# builds a `Widget::OverlayImage`, which draws a true-color image over the
# terminal using the external `w3mimgdisplay` helper.
#
# `w3mimgdisplay` ships with w3m-img (package `w3m-img`/`w3m`). If it is not
# installed, this program still runs: it shows a placeholder box explaining how
# to enable image rendering instead of loading the file (which would otherwise
# fail at draw time, exactly as Blessed's widget does without w3m).
#
# Pass an image path as the first argument, or it defaults to one of the repo's
# screenshots.
class X
  include Crysterm

  # Same locations `W3MImageDisplay` searches (plus the override env var).
  W3M_PATHS = [
    "/usr/lib/w3m/w3mimgdisplay",
    "/usr/libexec/w3m/w3mimgdisplay",
    "/usr/lib64/w3m/w3mimgdisplay",
    "/usr/libexec64/w3m/w3mimgdisplay",
    "/usr/local/libexec/w3m/w3mimgdisplay",
  ]

  def w3m_available?
    ([ENV["W3MIMGDISPLAY_ENV"]?] + W3M_PATHS).any? { |p| p && File.exists?(p) }
  end

  def initialize
    s = Screen.new always_propagate: [::Tput::Key::CtrlQ]

    # Default to a bundled screenshot. Look in ../screenshots (running from
    # test/) first, then fall back to ./screenshots (running from the repo root).
    file = ARGV[0]? || begin
      up = File.expand_path(File.join(__DIR__, "..", "screenshots", "widget.png"))
      here = File.expand_path(File.join("screenshots", "widget.png"))
      File.exists?(up) ? up : here
    end

    # The factory returns a `Widget::OverlayImage` for `type: Overlay`.
    img = Widget::Image.new(
      type: Widget::Image::Type::Overlay,
      parent: s,
      top: "center",
      left: "center",
      width: "50%",
      height: "50%",
      stretch: true,
      draggable: true,
      style: Style.new(bg: "green", border: true),
    )

    if w3m_available?
      img.load file
    else
      Widget::Box.new \
        parent: s,
        top: 0,
        left: 0,
        height: 3,
        width: "100%",
        parse_tags: true,
        content: "{yellow-fg}w3mimgdisplay not found.{/} Install w3m-img (or set " \
                 "W3MIMGDISPLAY_ENV) to render images. Showing a placeholder box.\n" \
                 "Press q to quit.",
        style: Style.new(border: true)
    end

    img.focus

    s.on(Crysterm::Event::KeyPress) do |e|
      if e.char == 'q' || e.key == ::Tput::Key::CtrlQ
        s.destroy
        exit
      end

      # Arrow keys move the image around (clamped to the screen). Each move
      # triggers a render: `OverlayImage` redraws the overlay on top at the new
      # spot and clears its previous position, so the image follows the box
      # without ghosting and without being clobbered by the redrawn cells.
      case e.key
      when ::Tput::Key::Left  then img.left = Math.max(0, img.aleft - 2)
      when ::Tput::Key::Right then img.left = Math.min(s.awidth - img.awidth, img.aleft + 2)
      when ::Tput::Key::Up    then img.top = Math.max(0, img.atop - 1)
      when ::Tput::Key::Down  then img.top = Math.min(s.aheight - img.aheight, img.atop + 1)
      end

      s.render
    end

    # A single initial render shows the image; it then stays painted on top
    # across every later render, following the box as the arrow keys move it.
    # `s.exec` issues that first render.
    s.exec
  end
end

X.new
