# IMPRESSIVE DEMO: a big-text digital clock.
#
# `Widget::BigText` renders text using a bitmap font scaled up into cells. Here
# it shows a live HH:MM clock with a seconds bar and date below.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "Clock"
s.show_fps = nil

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}BigText clock{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#202838")

clock = Widget::BigText.new \
  parent: s, top: 2, left: "center", height: 8,
  content: "00:00", style: Style.new(fg: "#40e0c0")

secbar = Widget::ProgressBar.new \
  parent: s, top: 11, left: 18, width: 44, height: 1,
  filled: 0, style: Style.new(fg: "#40e0c0", bg: "#283038")

datebox = Widget::Box.new \
  parent: s, top: 13, left: 0, width: "100%", height: 1, align: :hcenter,
  content: "", style: Style.new(fg: "#a0b0c0", bg: "black")

months = %w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec]
days = %w[Sun Mon Tue Wed Thu Fri Sat]
s.every(0.2.seconds) do
  t = Time.local
  clock.set_content t.to_s("%H:%M")
  secbar.filled = ((t.second / 59.0) * 100).to_i
  datebox.content = "#{days[t.day_of_week.value % 7]}  #{t.day} #{months[t.month - 1]} #{t.year}   :%02d" % t.second
end

s.exec
