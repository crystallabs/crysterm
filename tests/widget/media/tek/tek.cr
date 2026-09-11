# Demo: an image on a Tektronix 4014 storage-tube display.
#
# `Widget::Media::Tek` emits `ESC[?38h`, switching an xterm built with
# --enable-tek4014 into Tektronix mode, which opens a separate window and
# draws on a simulated green storage tube. The image is dithered to 1 bit and
# drawn as horizontal vector runs.
#
# Unlike the other image widgets this takes over a separate window; it
# requires an xterm with tek4014 support.

require "../../../../src/crysterm"

alias CT = Crysterm
alias CW = CT::Widgets

s = CT::Window.new title: "Tek"

CW::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: "100%",
  content: "{center}Media::Tek · Tektronix 4014 vectors · see the separate \"tektronix\" window{/center}",
  parse_tags: true, style: CT::Style.new(fg: "#33ff66", bg: "black")

CW::MediaTek.new \
  parent: s,
  dither: (ENV["TEK_DITHER"]? != "0" ? CT::Widget::Media::Dither::Auto : CT::Widget::Media::Dither::None),
  invert: (ENV["TEK_INVERT"]? == "1"),
  # Fits into the 1024x780 Tek screen; Contain preserves aspect ratio.
  fit: (case ENV["TEK_FIT"]?
  when "stretch" then CT::Widget::Media::Fit::Stretch
  when "cover"   then CT::Widget::Media::Fit::Cover
  else                CT::Widget::Media::Fit::Contain
  end),
  file: "#{__DIR__}/../../../../data/image/matterhorn.png"

if secs = ENV["DEMO_SECONDS"]?
  spawn do
    sleep secs.to_f.seconds
    s.destroy
    exit
  end
end

s.update
s.exec
