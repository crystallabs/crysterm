require "./spec_helper"

include Crysterm

private def hscreen(w = 40, h = 12)
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new, width: w, height: h)
end

private def text_of(s) : String
  (0...s.aheight).map { |y| (0...s.awidth).map { |x| c = s.lines[y][x].char; c == '\0' ? ' ' : c }.join }.join("\n")
end

describe Crysterm::Widget::Graph::Donut do
  it "draws a braille ring and a centered percent readout" do
    s = hscreen
    saved = Crysterm::CSS.default_stylesheet
    Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
    begin
      d = Crysterm::Widget::Graph::Donut.new parent: s, top: 0, left: 0, width: 18, height: 11,
        value: 72, label: "CPU", type: Crysterm::Widget::Media::Type::Glyph,
        style: Crysterm::Style.new(border: true)
      s._render
      t = text_of s
      t.each_char.any? { |ch| ('⠁'..'⣿').includes?(ch) }.should be_true # ring
      t.includes?("72%").should be_true
      t.includes?("CPU").should be_true
      d.percent.should eq 72.0
    ensure
      Crysterm::CSS.default_stylesheet = saved
    end
  end

  it "emits DoubleValueChanged on value change" do
    s = hscreen
    d = Crysterm::Widget::Graph::Donut.new parent: s, width: 10, height: 6, value: 0,
      type: Crysterm::Widget::Media::Type::Glyph
    got = nil
    d.on(Crysterm::Event::DoubleValueChanged) { |e| got = e.value }
    d.value = 50
    got.should eq 50.0
  end

  it "leaves the unfilled remainder empty (no track traces by default)" do
    s = hscreen(20, 11)
    saved = Crysterm::CSS.default_stylesheet
    Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
    begin
      Crysterm::Widget::Graph::Donut.new parent: s, top: 0, left: 0, width: 20, height: 11,
        value: 8, show_label: false, type: Crysterm::Widget::Media::Type::Glyph,
        style: Crysterm::Style.new(border: true)
      s._render
      # The 8% arc sits near the top; the bottom interior rows must be blank
      # (a full track ring would have filled them, which was the bug).
      bottom = (7..9).map { |y| (1...19).map { |x| s.lines[y][x].char }.join }
      bottom.all? { |row| row.each_char.none? { |ch| ('⠁'..'⣿').includes?(ch) } }.should be_true
    ensure
      Crysterm::CSS.default_stylesheet = saved
    end
  end

  it "show_track draws a full ring with the (dark) track distinct from the arc" do
    s = hscreen(20, 11)
    saved = Crysterm::CSS.default_stylesheet
    Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
    begin
      Crysterm::Widget::Graph::Donut.new parent: s, top: 0, left: 0, width: 20, height: 11,
        value: 35, show_label: false, show_track: true,
        fill_color: 0x40E0D0, track_color: 0x404850,
        type: Crysterm::Widget::Media::Type::Glyph, style: Crysterm::Style.new(border: true)
      s._render
      fgs = [] of Int64
      (1...10).each do |y|
        (1...19).each do |x|
          c = s.lines[y][x]
          fgs << Crysterm::Attr.fg(c.attr) if ('⠁'..'⣿').includes?(c.char)
        end
      end
      # The dark track renders (alpha-keyed, not luminance-filtered) AND both the
      # arc color and the track color are present as distinct per-cell colors.
      fgs.includes?(0x40E0D0_i64).should be_true # arc
      fgs.includes?(0x404850_i64).should be_true # track
      # A full ring has far more lit cells than a 35% arc would alone.
      fgs.size.should be > 60
    ensure
      Crysterm::CSS.default_stylesheet = saved
    end
  end

  it "Canvas keys its glyph device on opacity (vector content)" do
    s = hscreen
    cv = Crysterm::Widget::Graph::Canvas.new parent: s, width: 10, height: 4,
      type: Crysterm::Widget::Media::Type::Glyph
    cv.device.as(Crysterm::Widget::Media::Glyph).alpha_key?.should be_true
  end
end

describe Crysterm::Widget::GaugeList do
  it "renders one labeled bar per gauge with percentages" do
    s = hscreen
    saved = Crysterm::CSS.default_stylesheet
    Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
    begin
      gl = Crysterm::Widget::GaugeList.new parent: s, top: 0, left: 0, width: 24, height: 5,
        style: Crysterm::Style.new(border: true)
      gl.add_item "cpu", 64
      gl.add_item "mem", 88, 0xE05050
      s._render
      t = text_of s
      t.includes?("cpu").should be_true
      t.includes?("mem").should be_true
      t.includes?("64%").should be_true
      t.includes?("88%").should be_true
      t.each_char.any? { |ch| " ▏▎▍▌▋▊▉█".includes?(ch) && ch != ' ' }.should be_true # block bar
    ensure
      Crysterm::CSS.default_stylesheet = saved
    end
  end

  it "updates a gauge value by label" do
    s = hscreen
    gl = Crysterm::Widget::GaugeList.new parent: s, width: 20, height: 4
    gl.add_item "a", 10
    gl["a"] = 90
    gl.gauges[0].value.should eq 90.0
  end
end

describe "Carousel (TabWidget auto-advance)" do
  it "starts a timer when auto_advance is set, and stops it when cleared" do
    s = hscreen
    c = Crysterm::Widget::TabWidget.new parent: s, width: 30, height: 8, auto_advance: 50.milliseconds
    c.add_tab "A", Crysterm::Widget::Box.new(content: "a")
    c.add_tab "B", Crysterm::Widget::Box.new(content: "b")
    c.auto_advance.should eq 50.milliseconds
    c.@carousel_timer.nil?.should be_false
    c.auto_advance = nil
    c.@carousel_timer.nil?.should be_true
  end

  it "next_tab cycles with wrap (the action the timer invokes)" do
    s = hscreen
    c = Crysterm::Widget::TabWidget.new parent: s, width: 30, height: 8
    c.add_tab "A", Crysterm::Widget::Box.new(content: "a")
    c.add_tab "B", Crysterm::Widget::Box.new(content: "b")
    c.current_index.should eq 0
    c.next_tab; c.current_index.should eq 1
    c.next_tab; c.current_index.should eq 0 # wrapped
  end
end
