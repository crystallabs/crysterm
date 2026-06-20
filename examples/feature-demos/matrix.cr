# IMPRESSIVE DEMO: "Matrix" digital rain.
#
# Shows off fast full-screen redraws and 24-bit color all at once: the entire
# screen is recomposed every frame as a single tagged string, where each glyph
# carries its own `{#rrggbb-fg}` TrueColor tag so trails fade smoothly from a
# bright head to deep green.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "Matrix rain"
s.show_fps = nil

w = s.awidth
h = s.aheight

screen_box = Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: "100%",
  parse_tags: true, style: Style.new(bg: "black")

POOL = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@#$%&*+=?<>/\\|".chars

heads = Array.new(w) { -rand(0..h).to_f }
speeds = Array.new(w) { 0.25 + rand * 0.7 }
lengths = Array.new(w) { 6 + rand(10) }

s.on(Event::KeyPress) do |e|
  if e.char == 'q' || e.key == Tput::Key::CtrlQ
    s.destroy
    exit
  end
end

spawn do
  loop do
    content = String.build do |io|
      h.times do |y|
        w.times do |x|
          dist = heads[x] - y
          if dist >= 0 && dist < lengths[x]
            ch = POOL.sample
            if dist < 1
              io << "{#ccffcc-fg}" << ch << "{/}"
            else
              frac = 1.0 - dist / lengths[x]
              g = (60 + 180 * frac).to_i.clamp(0, 255)
              io << ("{#00%02x22-fg}" % g) << ch << "{/}"
            end
          else
            io << ' '
          end
        end
        io << '\n' unless y == h - 1
      end
    end
    screen_box.content = content

    w.times do |x|
      heads[x] += speeds[x]
      if heads[x] - lengths[x] > h
        heads[x] = -rand(0..h).to_f
        speeds[x] = 0.25 + rand * 0.7
        lengths[x] = 6 + rand(10)
      end
    end

    s.render
    sleep 0.07.seconds
  end
end

s.exec
