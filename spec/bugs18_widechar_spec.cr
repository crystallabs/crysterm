require "./spec_helper"

include Crysterm

# Regression specs for three round-3 BUGS18 findings, all the same defect
# shape: measuring/painting text by codepoint count (`String#size`) instead of
# display-column width (`str_width`/`Unicode.width`), which under
# `full_unicode` undersizes or garbles wide (CJK/emoji) glyphs.
#
#   * B18-50 — DialogButtonBox#make_button sized a button as `text.size + 2`,
#     clipping/undersizing wide labels. Fixed to `str_width(text) + 2`.
#   * B18-65 — Marquee/SineScroller (via Effect::TextScroll) painted one
#     codepoint per terminal column, so wide glyphs swallowed/overwrote their
#     neighbor. Fixed with a display-column table (`rebuild_scroll_columns`/
#     `scroll_column`) and a `Window#put_wide` lead+continuation writer.
#   * B18-89 — StackedBar#legend_line budgeted the one-row legend with
#     `entry.size`, so a wide segment-label legend silently overran its
#     column budget and wrapped onto a second row. Fixed to `str_width(entry)`.
#
# Everything is driven headlessly over in-memory IOs, mirroring
# spec/bugs17_effects_spec.cr and the full_unicode `pending!` convention from
# spec/artificial_cursor_grapheme_spec.cr (CI environments without a UTF-8
# locale report `full_unicode_effective?` false).

private def fu_screen(width = 20, height = 10)
  s = Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height)
  s.full_unicode = true
  s
end

describe "BUGS18 wide-char measuring/painting" do
  describe "B18-50 DialogButtonBox#make_button" do
    it "sizes a custom button by display width, not codepoint count" do
      s = fu_screen
      pending! "full_unicode unavailable in this environment" unless s.full_unicode_effective?

      bb = Widget::DialogButtonBox.new(parent: s, top: 0, left: 0)
      text = "取消操作" # 4 CJK codepoints, 8 display columns
      btn = bb.add_button text, Widget::DialogButtonBox::Role::Accept

      text.size.should eq 4
      Crysterm::Unicode.display_width(text).should eq 8
      # Pre-fix this was `text.size + 2` == 6, undersizing the button and
      # clipping the label under the content engine's display-column wrap.
      btn.width.should eq 10
    end

    it "still sizes ASCII labels the same as before (no regression)" do
      s = fu_screen
      bb = Widget::DialogButtonBox.new(parent: s, top: 0, left: 0)
      btn = bb.add_button "Cancel", Widget::DialogButtonBox::Role::Reject
      btn.width.should eq 8 # "Cancel".size + 2, unchanged whether full_unicode or not
    end
  end

  describe "B18-65 Marquee wide-glyph painting" do
    it "claims a continuation cell for each wide glyph instead of swallowing its neighbor" do
      s = fu_screen
      pending! "full_unicode unavailable in this environment" unless s.full_unicode_effective?

      # 4 double-width kana, each 2 display columns: scroll_width == 8.
      Widget::Marquee.new parent: s, top: 0, left: 0,
        width: 8, height: 1, text: "ニュース"
      s.repaint # frame 0: the message exactly fills the widget, no scroll offset

      expected = ['ニ', 'ュ', 'ー', 'ス']
      expected.each_with_index do |ch, i|
        lead_x = i * 2
        s.lines[0][lead_x].char.should eq ch
        s.lines[0][lead_x].continuation?.should be_false
        s.lines[0][lead_x + 1].continuation?.should be_true
      end
    end

    it "blanks a lead glyph that would straddle the widget's right edge" do
      s = fu_screen
      pending! "full_unicode unavailable in this environment" unless s.full_unicode_effective?

      # Same message, but the widget is one column too narrow for the last
      # glyph's continuation: it must be blanked, not truncated into the
      # neighboring column.
      Widget::Marquee.new parent: s, top: 0, left: 0,
        width: 7, height: 1, text: "ニュース"
      s.repaint

      s.lines[0][0].char.should eq 'ニ'
      s.lines[0][2].char.should eq 'ュ'
      s.lines[0][4].char.should eq 'ー'
      # The 4th glyph's lead would need column 7, outside the 7-wide widget:
      # blanked instead of rendered half.
      s.lines[0][6].char.should eq ' '
      s.lines[0][6].continuation?.should be_false
    end

    it "blanks an orphaned continuation column when the paired lead has scrolled off the left edge" do
      s = fu_screen
      pending! "full_unicode unavailable in this environment" unless s.full_unicode_effective?

      m = Widget::Marquee.new parent: s, top: 0, left: 0,
        width: 8, height: 1, text: "ニュース"
      # Advance one column: 'ニ' (glyph 0)'s continuation now leads column 0,
      # with its lead scrolled out of view.
      1.times { m.step }
      s.repaint

      s.lines[0][0].char.should eq ' '
      s.lines[0][0].continuation?.should be_false
      s.lines[0][1].char.should eq 'ュ'
      s.lines[0][7].char.should eq ' ' # the next straddling lead, blanked (right edge again)
    end

    it "keeps painting a pure-ASCII message unchanged" do
      s = fu_screen
      m = Widget::Marquee.new parent: s, top: 0, left: 0,
        width: 6, height: 1, text: "AB"
      s.repaint
      w = m.awidth
      String.build { |io| (0...w).each { |x| io << s.lines[0][x].char } }
        .should eq String.build { |io| (0...w).each { |x| io << "AB"[x % 2] } }
    end
  end

  describe "B18-89 StackedBar legend" do
    it "keeps a one-row legend of wide segment labels within the interior width, unwrapped" do
      s = fu_screen(18, 8)
      pending! "full_unicode unavailable in this environment" unless s.full_unicode_effective?

      sb = Widget::Graph::StackedBar.new parent: s, top: 0, left: 0,
        width: 18, height: 8,
        segment_labels: ["空闲", "警告", "严重"],
        colors: %w[green yellow red],
        labels: %w[web db cache]
      sb.values = [[60, 30, 10], [20, 50, 30], [80, 15, 5]]
      s.repaint

      cols = sb.awidth - 0 # no border/padding on this box
      # No wrap: legend(1) + plot(6) + caption(1) == 8 real lines, not 9.
      sb._clines.size.should eq 8
      # str_width, not raw Unicode.display_width: `_clines.fake` holds the
      # POST-parse line, with `{color-fg}`/`{/}` legend tags already turned
      # into real SGR escape sequences. Those sequences' printable bytes
      # ("[32m") would otherwise count as extra display columns; str_width
      # strips SGR before measuring, matching what legend_line's own budget
      # check (also str_width) guaranteed at build time.
      sb.str_width(sb._clines.fake[0]).should be <= cols
      # The bottom caption row survives instead of being pushed off-screen.
      sb._clines.fake.last.should contain "web"
    end
  end
end
