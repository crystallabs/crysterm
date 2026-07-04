require "./spec_helper"

include Crysterm

# Behaviour-preservation specs for the WARM/COLD allocation reductions in
# Groups P and I (ALLOCS.md): calendar weekday-header caching (P1), tree indent
# memoization (P7), scrollbar no-op sync early-return (P6), and Font glyph miss
# caching (I1). Each verifies the observable output is unchanged after the
# allocation optimization.

private def api_screen(w = 40, h = 20)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

# Extracts the weekday-header line from a calendar's rendered content (line 1
# when the nav bar is visible, else line 0).
private def cal_header_line(cal : Crysterm::Widget::Calendar) : String
  lines = cal.content.split('\n')
  cal.navigation_bar_visible? ? lines[1] : lines[0]
end

describe "ALLOCS Group P/I behaviour preservation" do
  describe "P1 — Calendar weekday header caching" do
    it "keeps the header correct across format / first-day / grid changes" do
      s = api_screen
      cal = Widget::Calendar.new parent: s, top: 0, left: 0, width: 24, height: 12

      # Default: ShortDayNames, Sunday-first, no grid.
      cal_header_line(cal).should eq "Su Mo Tu We Th Fr Sa"

      # First day of week rotates the labels (cache key includes it).
      cal.first_day_of_week = ::Time::DayOfWeek::Monday
      cal_header_line(cal).should eq "Mo Tu We Th Fr Sa Su"

      # Grid visibility swaps the separator (cache key includes it).
      cal.grid_visible = true
      cal_header_line(cal).should eq "Mo│Tu│We│Th│Fr│Sa│Su"

      # Toggling back returns the original cached form (invalidation works).
      cal.grid_visible = false
      cal.first_day_of_week = ::Time::DayOfWeek::Sunday
      cal_header_line(cal).should eq "Su Mo Tu We Th Fr Sa"

      # Single-letter format.
      cal.horizontal_header_format = Widget::Calendar::HorizontalHeaderFormat::SingleLetterDayNames
      cal_header_line(cal).should eq " S  M  T  W  T  F  S"
    end

    it "renders day cells with two-column right-justified numbers" do
      s = api_screen
      cal = Widget::Calendar.new parent: s, top: 0, left: 0, width: 24, height: 12,
        date: Time.utc(2024, 1, 15)
      # Day numbers 1..9 are space-padded to width 2; the selected day (15) is
      # wrapped in {reverse} tags but still shows "15".
      cal.content.should contain " 1"
      cal.content.should contain "{reverse}15{/reverse}"
      cal.content.should contain "31"
    end
  end

  describe "P7 — Tree indent memoization" do
    it "indents each row by depth * indent and rebuilds when indent changes" do
      s = api_screen
      tree = Widget::Tree.new parent: s, top: 0, left: 0, width: 30, height: 12
      root = tree.add "root"
      child = root.add "child"
      child.add "grandchild"
      tree.expand_all

      rows = tree.ritems
      rows[0].should eq "\u{25BE} root"    # depth 0: no indent, expanded marker
      rows[1].should eq "  \u{25BE} child" # depth 1: 2 spaces
      rows[2].should eq "      grandchild" # depth 2: 4 spaces + leaf marker ' ' + ' '

      # Change the indent width; a rebuild must reflect the new spacing
      # (the memoized indent strings are invalidated on the setter).
      tree.indent = 4
      tree.rebuild
      rows = tree.ritems
      rows[1].should eq "    \u{25BE} child"   # depth 1: now 4 spaces
      rows[2].should eq "          grandchild" # depth 2: now 8 spaces + leaf ' ' + ' '
    end
  end

  describe "P6 — ScrollBar sync early-return" do
    it "keeps tracking the target's scroll position (idempotent syncs)" do
      s = api_screen 40, 10
      content = (1..40).map { |i| "line #{i}" }.join('\n')
      box = Widget::ScrollableBox.new parent: s, top: 0, left: 0, width: 20, height: 8,
        content: content
      bar = Widget::ScrollBar.new parent: s, top: 0, left: 20, width: 1, height: 8
      s.render
      bar.attach box
      s.render

      bar.value.should eq 0

      # Scrolling the target drives the bar (via the Scroll event → sync).
      box.scroll_to 5
      s.render
      bar.value.should eq 5

      # A redundant scroll to the same offset is a no-op; value stays put.
      box.scroll_to 5
      s.render
      bar.value.should eq 5

      # A further scroll still updates the bar (early-return didn't strand it).
      box.scroll_to 10
      s.render
      bar.value.should eq 10
    end
  end

  describe "I1 — Font glyph miss caching" do
    it "falls back to '?' for a missing glyph and caches the result" do
      f = Crysterm::Font.default_normal
      q = f.glyph "?"

      # A codepoint Unifont does not cover falls back to the '?' glyph.
      miss = f.glyph "\u{10FFFD}"
      miss.should eq q

      # The resolved (fallback) grid is cached: a repeat returns the same object.
      f.glyph("\u{10FFFD}").should be(miss)

      # A real glyph resolves to a non-blank grid, stably cached.
      a = f.glyph "A"
      a.size.should eq f.height
      a.any? { |row| row.any? { |px| px == 1 } }.should be_true
      f.glyph("A").should be(a)
    end
  end
end
