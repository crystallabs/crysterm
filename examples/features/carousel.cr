# IMPRESSIVE DEMO: a carousel — a TabWidget that auto-advances.
require "../../src/crysterm"
include Crysterm

s = Screen.new title: "Carousel"
car = Widgets::Carousel.new parent: s, width: "100%", height: "100%",
  auto_advance: 2.seconds, style: Style.new(border: true)
3.times do |i|
  car.add_tab "Page #{i + 1}", Widget::Box.new(
    content: "{center}This is page #{i + 1}.\nAuto-advances every 2s.{/center}",
    parse_tags: true, style: Style.new(fg: "white", bg: i.even? ? "#102030" : "#201020"))
end
s.exec
