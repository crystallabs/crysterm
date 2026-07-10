require "./spec_helper"

include Crysterm

# BUGS13 M-Z paint-path regression coverage:
#   M2 — Media::Ansi/Media::Glyph draw_sample must not wrap rows/columns for a
#        widget partially off the top/left screen edge (negative coords wrap
#        through Indexable#[]?).
#   M4 — TextEdit#paint_document must not wrap left-clipped columns to the
#        right end of the row (negative absolute columns).
#   M6 — TextBrowser: a click on empty space (right of a line / below the
#        text) must not activate the nearest trailing link.

private def paint_screen(width = 20, height = 6)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height)
end

private def red_bitmap(w = 4, h = 4)
  red = PNGGIF::Pixel.new(255, 0, 0, 255)
  Array(Array(PNGGIF::Pixel)).new(h) { Array(PNGGIF::Pixel).new(w, red) }
end

private def click(s, x : Int32, y : Int32)
  s.dispatch_mouse(::Tput::Mouse::Event.new(
    ::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left, x, y, source: :test))
end

describe "BUGS13 M2: media backends clamp negative coordinates" do
  it "Ansi does not wrap rows for an image partially above the screen" do
    s = paint_screen(20, 6)
    img = Widget::Media::Ansi.new parent: s, top: -2, left: 0, width: 4, height: 4,
      fit: Widget::Media::Fit::Stretch
    img.bitmap = red_bitmap(4, 4)
    s._render

    base = s.lines[4][10].attr # an untouched reference cell
    (0..3).each do |x|
      # Rows -2/-1 used to wrap to the bottom of the buffer (rows 4/5).
      s.lines[4][x].attr.should eq base
      s.lines[5][x].attr.should eq base
    end
    # Sanity: the visible part did paint.
    s.lines[0][0].attr.should_not eq base
  ensure
    s.try &.destroy
  end

  it "Glyph does not wrap columns for an image partially left of the screen" do
    s = paint_screen(20, 6)
    img = Widget::Media::Glyph.new parent: s, top: 0, left: -2, width: 4, height: 2,
      mode: Widget::Media::Glyph::Mode::Block, fit: Widget::Media::Fit::Stretch
    img.bitmap = red_bitmap(8, 4)
    s._render

    base = s.lines[0][10].attr
    [18, 19].each do |x|
      # Columns -2/-1 used to wrap to the right end of the row (18/19).
      s.lines[0][x].attr.should eq base
      s.lines[1][x].attr.should eq base
    end
    s.lines[0][0].attr.should_not eq base
  ensure
    s.try &.destroy
  end
end

describe "BUGS13 M4: paint_document clamps negative columns" do
  it "does not wrap left-clipped text to the right end of the row" do
    s = paint_screen(20, 4)
    Widget::PlainTextEdit.new parent: s, top: 0, left: -3, width: 10, height: 2,
      content: "hello world"
    s._render

    # The first visible character is the 4th of the row's text.
    s.lines[0][0].char.should eq 'l'
    # Columns -3..-1 used to wrap to cells 17..19.
    (17..19).each do |x|
      s.lines[0][x].char.should eq ' '
    end
  ensure
    s.try &.destroy
  end
end

describe "BUGS13 M6: TextBrowser click hit-testing is exact" do
  it "does not activate a trailing link from clicks on empty space" do
    s = paint_screen(40, 8)
    tb = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: 40, height: 8
    tb.document = TextDocument.from_markdown("go [one](u://1) and [two](u://2)")
    s._render

    clicked = [] of String
    tb.on(Crysterm::Event::AnchorClick) { |e| clicked << e.url }

    # Right of the line's end: position_at clamps to line end, whose format
    # resolves to the trailing link — must NOT activate.
    click s, 30, 0
    clicked.should be_empty

    # Below the last text row: position_at clamps to the last row.
    click s, 5, 5
    clicked.should be_empty

    # Exactly on the first link ("one" spans columns 3..5 of "go one and two").
    click s, 4, 0
    clicked.should eq ["u://1"]
  ensure
    s.try &.destroy
  end
end
