require "./spec_helper"

include Crysterm

# Regression spec for BUGS11 #22 and #23 (both in src/widget_graph_scale.cr).
#
# #22 — `Scale.eighths` fed a non-finite value passed straight through `clamp`
# (NaN survives, since all NaN comparisons are false) into `NaN.round.to_i`,
# which raises `OverflowError` and crashes the render of Bar/StackedBar/Gauge.
# It now guards non-finite input at the top (like sibling `Scale.fmt`).
#
# #23 — `Scale.center_to`/`center` measured/truncated captions in CODEPOINTS
# (`text.size` / `text[0, width]`) while plot rows are laid out in terminal
# DISPLAY columns, so wide (CJK/emoji) labels overflowed their field. It now
# takes a `full_unicode` flag (threaded from the widget via `BarChart#field_line`)
# and, when true, measures/truncates by Unicode display width (mirroring
# `TableLayout#pad_cell_to`); when false the legacy codepoint behavior is kept.

private def bgs_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

describe "BUGS11 #22 Scale.eighths guards non-finite values" do
  it "returns 0 for a NaN value instead of raising OverflowError" do
    rows = 6
    Crysterm::Widget::Graph::Scale.eighths(Float64::NAN, 0.0, 100.0, rows).should eq 0
  end

  it "returns 0 for +/-Infinity too" do
    Crysterm::Widget::Graph::Scale.eighths(Float64::INFINITY, 0.0, 100.0, 6).should eq 0
    Crysterm::Widget::Graph::Scale.eighths(-Float64::INFINITY, 0.0, 100.0, 6).should eq 0
  end

  it "still maps finite values normally after the guard" do
    Crysterm::Widget::Graph::Scale.eighths(50.0, 0.0, 100.0, 6).should eq 24
  end

  it "renders a Bar containing a NaN value without raising" do
    s = bgs_screen
    bar = Crysterm::Widget::Graph::Bar.new parent: s, top: 0, left: 0, width: 20, height: 6, maximum: 100.0
    bar.values = [50.0, 0.0/0.0]
    # Without the #22 fix this render pass crashes with OverflowError.
    s.repaint
    bar.values[0].should eq 50.0
    bar.values[1].nan?.should be_true
  end
end

describe "BUGS11 #23 Scale.center_to measures by display width under full_unicode" do
  it "truncates a CJK label so it never exceeds the field width in columns (full_unicode true)" do
    # "日本語" is 3 codepoints but 6 display columns.
    res = Crysterm::Widget::Graph::Scale.center("日本語", 4, full_unicode: true)
    Crysterm::Unicode.display_width(res).should be <= 4
  end

  it "pads by display width so the field is exactly filled (full_unicode true)" do
    res = Crysterm::Widget::Graph::Scale.center("日本語", 8, full_unicode: true)
    Crysterm::Unicode.display_width(res).should eq 8
  end

  it "never splits a wide grapheme when clipping (full_unicode true)" do
    # width 3 can hold only one 2-column glyph without splitting.
    res = Crysterm::Widget::Graph::Scale.center("日本語", 3, full_unicode: true)
    res.should eq "日"
    Crysterm::Unicode.display_width(res).should be <= 3
  end

  it "keeps the legacy codepoint sizing when full_unicode is false" do
    # Old behavior: measured/padded by `text.size` (3), so it fits width 4 and
    # is padded to 4 CODEPOINTS (display width is not consulted).
    fu_off = Crysterm::Widget::Graph::Scale.center("日本語", 4, full_unicode: false)
    # Matches the pre-fix implementation exactly: pad = 4 - 3 = 1, left = 0.
    fu_off.should eq "日本語 "
    fu_off.size.should eq 4
    # The default (no flag) must be the legacy codepoint behavior.
    Crysterm::Widget::Graph::Scale.center("日本語", 4).should eq fu_off
  end

  it "truncates by codepoints when full_unicode is false" do
    Crysterm::Widget::Graph::Scale.center("日本語", 2, full_unicode: false).should eq "日本"
  end
end
