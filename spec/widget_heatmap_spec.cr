require "./spec_helper"

include Crysterm

private def hmscreen(w = 40, h = 16)
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new, width: w, height: h)
end

private def hm_mouse(action, x, y, button = ::Tput::Mouse::Button::Left)
  ::Tput::Mouse::Event.new(action, button, x, y, source: :test)
end

alias HeatMap = Crysterm::Widget::Graph::HeatMap

describe Crysterm::Widget::Graph::HeatMap do
  it "constructs with data and defaults" do
    hm = HeatMap.new width: 20, height: 10,
      data: [[1.0, 2.0], [3.0, 4.0]]
    hm.data.size.should eq 2
    hm.colormap.should eq :viridis
    hm.show_legend?.should be_true
    hm.show_labels?.should be_true
    hm.symmetric?.should be_false
  end

  it "auto-computes vmin/vmax from the finite data" do
    hm = HeatMap.new width: 20, height: 10
    hm.vmin.should be_nil # unset (auto)
    hm.vmax.should be_nil
    hm.data = [[10.0, 20.0], [30.0, 40.0]]
    lo, hi = hm.value_range
    lo.should eq 10.0
    hi.should eq 40.0
  end

  it "honors explicit vmin/vmax" do
    hm = HeatMap.new width: 20, height: 10,
      data: [[10.0, 20.0]], vmin: 0.0, vmax: 100.0
    hm.value_range.should eq({0.0, 100.0})
  end

  it "maps color_for endpoints to the colormap's first/last stop" do
    stops = HeatMap::COLORMAPS[:viridis]
    hm = HeatMap.new width: 20, height: 10,
      colormap: :viridis, data: [[0.0, 100.0]], vmin: 0.0, vmax: 100.0
    hm.color_for(0.0).should eq stops.first.rgb
    hm.color_for(100.0).should eq stops.last.rgb
    # A mid value lands somewhere strictly between (interpolated).
    mid = hm.color_for(50.0)
    mid.should_not eq stops.first.rgb
    mid.should_not eq stops.last.rgb
  end

  it "clamps out-of-range values to the endpoints" do
    stops = HeatMap::COLORMAPS[:grayscale]
    hm = HeatMap.new width: 10, height: 6,
      colormap: :grayscale, data: [[0.0, 1.0]], vmin: 0.0, vmax: 1.0
    hm.color_for(-5.0).should eq stops.first.rgb
    hm.color_for(5.0).should eq stops.last.rgb
  end

  it "centers a diverging map at 0 when symmetric" do
    hm = HeatMap.new width: 20, height: 10,
      colormap: :coolwarm, symmetric: true,
      data: [[-2.0, 4.0]]
    hm.value_range.should eq({-4.0, 4.0})
    # 0 is the midpoint -> the middle stop's (near-)white. LUT quantization
    # (index 128 samples t≈0.502) shifts it by a step or two, so compare
    # channel-wise within tolerance rather than exact-equal.
    wr, wg, wb = Crysterm::Widget::Media.rgb24 HeatMap::COLORMAPS[:coolwarm][1].rgb
    r, g, b = Crysterm::Widget::Media.rgb24 hm.color_for(0.0)
    (r - wr).abs.should be <= 8
    (g - wg).abs.should be <= 8
    (b - wb).abs.should be <= 8
  end

  it "guards vmax == vmin (all-equal values)" do
    hm = HeatMap.new width: 10, height: 6,
      data: [[5.0, 5.0], [5.0, 5.0]]
    lo, hi = hm.value_range
    (hi > lo).should be_true # widened so normalization stays finite
    # Doesn't raise / produces a valid color.
    hm.color_for(5.0).should be_a(Int32)
  end

  it "handles an all-NaN matrix without raising" do
    hm = HeatMap.new width: 10, height: 6,
      data: [[Float64::NAN, Float64::NAN]]
    lo, hi = hm.value_range
    (hi > lo).should be_true # falls back to 0..1
    hm.color_for(0.0).should be_a(Int32)
  end

  it "handles single-row and single-column data" do
    row = HeatMap.new width: 20, height: 8, data: [[1.0, 2.0, 3.0]]
    row.value_range.should eq({1.0, 3.0})
    col = HeatMap.new width: 8, height: 20, data: [[1.0], [2.0], [3.0]]
    col.value_range.should eq({1.0, 3.0})
  end

  it "rebuilds the color scale when the colormap changes" do
    hm = HeatMap.new width: 10, height: 6,
      colormap: :grayscale, data: [[0.0, 1.0]], vmin: 0.0, vmax: 1.0
    hm.color_for(0.0).should eq HeatMap::COLORMAPS[:grayscale].first.rgb
    hm.colormap = :magma
    hm.colormap.should eq :magma
    hm.color_for(0.0).should eq HeatMap::COLORMAPS[:magma].first.rgb
  end

  it "renders a grid of colored cells without raising" do
    s = hmscreen
    saved = Crysterm::CSS.default_stylesheet
    Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
    begin
      HeatMap.new parent: s, top: 0, left: 0, width: 30, height: 12,
        colormap: :viridis, data: [[0.0, 1.0, 2.0], [3.0, 4.0, 5.0]],
        type: Crysterm::Widget::Media::Type::Glyph,
        style: Crysterm::Style.new(border: true)
      s._render
      # Some interior cell picked up a real RGB background (a colored block):
      # a resolved color is `0..0xFFFFFF`, below the `COLOR_DEFAULT` sentinel.
      any_bg = (1...11).any? do |y|
        (1...29).any? do |x|
          bg = Crysterm::Attr.bg(s.lines[y][x].attr)
          bg >= 0 && bg < Crysterm::Attr::COLOR_DEFAULT
        end
      end
      any_bg.should be_true
    ensure
      Crysterm::CSS.default_stylesheet = saved
    end
  end

  it "skips NaN cells when painting (leaves them transparent)" do
    s = hmscreen
    saved = Crysterm::CSS.default_stylesheet
    Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
    begin
      hm = HeatMap.new parent: s, top: 0, left: 0, width: 30, height: 12,
        show_legend: false, show_labels: false,
        data: [[Float64::NAN, Float64::NAN], [Float64::NAN, Float64::NAN]],
        type: Crysterm::Widget::Media::Type::Glyph,
        style: Crysterm::Style.new(border: true)
      # All cells NaN -> paint_grid fills nothing; render must not raise.
      s._render
      hm.data.size.should eq 2
    ensure
      Crysterm::CSS.default_stylesheet = saved
    end
  end

  it "emits CellHover with the (row, col, value) under the pointer" do
    s = hmscreen
    saved = Crysterm::CSS.default_stylesheet
    Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
    begin
      hm = HeatMap.new parent: s, top: 0, left: 0, width: 32, height: 12,
        show_legend: false, show_labels: false,
        data: [[10.0, 20.0], [30.0, 40.0]],
        type: Crysterm::Widget::Media::Type::Glyph
      s._render

      seen = [] of {Int32, Int32, Float64}
      hm.on(Crysterm::Event::CellHover) { |e| seen << {e.row, e.col, e.value} }

      # Hover the top-left cell region, then the bottom-right.
      s.dispatch_mouse hm_mouse(::Tput::Mouse::Action::Move, 1, 1)
      s.dispatch_mouse hm_mouse(::Tput::Mouse::Action::Move, hm.awidth - 2, hm.aheight - 2)

      seen.size.should eq 2
      seen[0].should eq({0, 0, 10.0})
      seen[1].should eq({1, 1, 40.0})
    ensure
      Crysterm::CSS.default_stylesheet = saved
    end
  end

  it "emits CellHover only when the cell changes" do
    s = hmscreen
    saved = Crysterm::CSS.default_stylesheet
    Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
    begin
      hm = HeatMap.new parent: s, top: 0, left: 0, width: 32, height: 12,
        show_legend: false, show_labels: false,
        data: [[1.0, 2.0], [3.0, 4.0]],
        type: Crysterm::Widget::Media::Type::Glyph
      s._render

      count = 0
      hm.on(Crysterm::Event::CellHover) { count += 1 }
      # Two moves within the same top-left cell -> one emit.
      s.dispatch_mouse hm_mouse(::Tput::Mouse::Action::Move, 1, 1)
      s.dispatch_mouse hm_mouse(::Tput::Mouse::Action::Move, 2, 1)
      count.should eq 1
    ensure
      Crysterm::CSS.default_stylesheet = saved
    end
  end
end
