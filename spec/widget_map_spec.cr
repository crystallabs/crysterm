require "./spec_helper"

include Crysterm

private def map_screen
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 78, height: 22)
end

private def cells_text(s) : String
  (0...s.aheight).map { |y| (0...s.awidth).map { |x| c = s.lines[y][x].char; c == '\0' ? ' ' : c }.join }.join("\n")
end

describe Crysterm::Widget::Graph::Map do
  it "embeds the coastline dataset" do
    Crysterm::Widget::Graph::Map::WORLD.size.should be > 50
    Crysterm::Widget::Graph::Map::WORLD.sum(&.size).should be > 1000
  end

  it "draws coastlines (braille) and coordinate markers (glyphs)" do
    s = map_screen
    saved = Crysterm::CSS.default_stylesheet
    Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
    begin
      m = Crysterm::Widget::Graph::Map.new parent: s, top: 0, left: 0, width: 78, height: 22,
        type: Crysterm::Widget::Media::Type::Glyph, style: Crysterm::Style.new(border: true)
      m.add_marker latitude: 40.71, longitude: -74.0, label: "NYC", color: 0xE05050
      m.add_marker latitude: 35.68, longitude: 139.69, label: "Tokyo", color: 0x40E0D0
      s._render

      text = cells_text s
      # Coastlines rendered as braille.
      text.each_char.any? { |ch| ('⠁'..'⣿').includes?(ch) }.should be_true
      # Markers + labels overlaid as terminal glyphs.
      text.includes?('●').should be_true
      text.includes?("NYC").should be_true
      text.includes?("Tokyo").should be_true
    ensure
      Crysterm::CSS.default_stylesheet = saved
    end
  end

  it "does not crash rendering a zero-span viewport with a marker at its center" do
    # `look_at(lat, lon, 0, 0)` collapses the window to a point: `min_lon ==
    # max_lon` and `min_lat == max_lat`. A marker sitting exactly there clears the
    # in-bounds check, so the marker projection used to divide by that zero span,
    # producing NaN — and `NaN.to_i` raises `OverflowError`, tearing down render.
    s = map_screen
    saved = Crysterm::CSS.default_stylesheet
    Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
    begin
      m = Crysterm::Widget::Graph::Map.new parent: s, top: 0, left: 0, width: 78, height: 22,
        type: Crysterm::Widget::Media::Type::Glyph
      m.look_at 12.0, 34.0, 0, 0
      m.add_marker latitude: 12.0, longitude: 34.0, char: 'X'
      # The defect raised OverflowError here; with the guard, render completes.
      s._render
    ensure
      Crysterm::CSS.default_stylesheet = saved
    end
  end

  it "projects markers to the correct hemisphere" do
    s = map_screen
    saved = Crysterm::CSS.default_stylesheet
    Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
    begin
      m = Crysterm::Widget::Graph::Map.new parent: s, top: 0, left: 0, width: 78, height: 22,
        type: Crysterm::Widget::Media::Type::Glyph
      m.add_marker latitude: 0.0, longitude: -150.0, char: 'W'
      m.add_marker latitude: 0.0, longitude: 150.0, char: 'E'
      s._render
      rows = (0...s.aheight).map { |y| (0...s.awidth).map { |x| s.lines[y][x].char }.join }
      wx = rows.compact_map(&.index('W')).first?
      ex = rows.compact_map(&.index('E')).first?
      wx.should_not be_nil
      ex.should_not be_nil
      (wx.not_nil! < ex.not_nil!).should be_true # western marker left of eastern
    ensure
      Crysterm::CSS.default_stylesheet = saved
    end
  end
end
