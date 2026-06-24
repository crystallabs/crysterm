# IMPRESSIVE DEMO: a world map with live markers.
#
# `Widget::Graph::Map` draws coastlines on a backend-agnostic `Canvas`
# (sixel/kitty where available, else braille) and places markers by
# latitude/longitude, modeled after Qt Location's Map. Press `q` / Ctrl+C.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "Map"

map = Widget::Graph::Map.new \
  parent: s, top: 0, left: 0, width: "100%", height: "100%",
  land_color: 0x4E9A50, style: Style.new(fg: "white", bg: "#0A0E14", border: true)

cities = [
  {"New York", 40.71, -74.0, 0xE05050},
  {"London", 51.5, -0.12, 0x40E0D0},
  {"Tokyo", 35.68, 139.69, 0xE0A040},
  {"Sydney", -33.87, 151.21, 0x60C040},
  {"Rio", -22.91, -43.17, 0xD060C0},
  {"Cairo", 30.04, 31.24, 0x4090E0},
]
cities.each do |(name, lat, lon, color)|
  map.add_marker latitude: lat, longitude: lon, label: name, color: color
end

# Blink the markers on a timer to show live updates.
on = true
s.every(0.6.seconds) do
  on = !on
  map.clear_markers
  cities.each do |(name, lat, lon, color)|
    map.add_marker latitude: lat, longitude: lon,
      char: on ? '●' : '○', label: name, color: color
  end
  map.refresh
end

s.exec
