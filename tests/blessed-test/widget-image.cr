require "../../src/crysterm"

# Port of Blessed's test/widget-image.js
#
# Demonstrates `Widget::Media`, the image factory. With `type: Overlay` it
# builds a `Widget::Media::Overlay`, which draws a true-color image over the
# terminal using the external `w3mimgdisplay` helper.
#
# `w3mimgdisplay` ships with w3m-img (package `w3m-img`/`w3m`). If not
# installed, shows a placeholder box explaining how to enable image rendering
# instead of loading the file.
#
# Pass an image path as the first argument, or it defaults to one of the repo's
# bundled sample images.
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
    s = Window.new always_propagated_keys: [::Tput::Key::CtrlQ]

    # Default to a bundled sample image: ../../data/image (running from
    # tests/blessed-test/), falling back to ./data/image (running from repo root).
    file = ARGV[0]? || begin
      up = File.expand_path(File.join(__DIR__, "..", "..", "data", "image", "widget.png"))
      here = File.expand_path(File.join("data", "image", "widget.png"))
      File.exists?(up) ? up : here
    end

    # Factory returns `Media::Ansi | Media::Overlay` (normalized to `Box+`);
    # narrow to the overlay backend to use overlay-specific API like `#load`.
    img = Widget::Media.new(
      type: Widget::Media::Type::Overlay,
      parent: s,
      top: "center",
      left: "center",
      width: "50%",
      height: "50%",
      draggable: true,
      style: Style.new(bg: "green", border: true),
    ).as(Widget::Media::Overlay)

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

      # Arrow keys move the image around (clamped to the screen); each move
      # triggers a render so `Media::Overlay` redraws at the new spot and clears
      # its previous position (no ghosting).
      case e.key
      when ::Tput::Key::Left  then img.left = Math.max(0, img.aleft - 2)
      when ::Tput::Key::Right then img.left = Math.min(s.awidth - img.awidth, img.aleft + 2)
      when ::Tput::Key::Up    then img.top = Math.max(0, img.atop - 1)
      when ::Tput::Key::Down  then img.top = Math.min(s.aheight - img.aheight, img.atop + 1)
      end

      s.render
    end

    # `s.exec` issues the initial render; the image then stays painted on top
    # across later renders as the arrow keys move it.
    s.exec
  end
end

X.new
