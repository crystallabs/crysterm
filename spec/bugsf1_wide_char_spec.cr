require "./spec_helper"

include Crysterm

# BUGS-F1 wide-character / grapheme rendering findings: 26 (WIDE table gap),
# 11 (orphan continuation at the left screen edge), 10 (changed continuation
# cell counted as a column in `#draw`), and 28 (plane fold skips a
# grapheme-overlay difference). See BUGS-F1.md for full detail.

private def fu_screen(width, height)
  outio = IO::Memory.new
  s = Crysterm::Window.new(
    input: IO::Memory.new, output: outio, error: IO::Memory.new,
    width: width, height: height)
  s.full_unicode = true
  pending! "full_unicode unavailable in this environment" unless s.full_unicode_effective?
  {s, outio}
end

# ---------------------------------------------------------------------------
# Finding 26: wide-emoji ranges U+231A..U+27BF missing from the WIDE table.
# ---------------------------------------------------------------------------
describe "BUGS-F1 #26: WIDE table covers the U+231A..U+27BF emoji gap" do
  # A representative sample from every inserted range/singleton. All are
  # East-Asian-Width = W and render 2 cells wide in conforming terminals; before
  # the fix `codepoint_width` returned 1 for each, shifting content after them.
  {
    '\u{231A}', '\u{231B}',             # ⌚⌛
    '\u{23E9}', '\u{23EC}',             # ⏩⏬
    '\u{23F0}', '\u{23F3}',             # ⏰⏳
    '\u{25FD}', '\u{25FE}',             # ◽◾
    '\u{2614}', '\u{2615}',             # ☔☕
    '\u{2648}', '\u{2653}',             # ♈♓
    '\u{267F}',                         # ♿
    '\u{2693}',                         # ⚓
    '\u{26A1}',                         # ⚡
    '\u{26AA}', '\u{26AB}',             # ⚪⚫
    '\u{26BD}', '\u{26BE}',             # ⚽⚾
    '\u{26C4}', '\u{26C5}',             # ⛄⛅
    '\u{26CE}',                         # ⛎
    '\u{26D4}',                         # ⛔
    '\u{26EA}',                         # ⛪
    '\u{26F2}', '\u{26F3}', '\u{26F5}', # ⛲⛳⛵
    '\u{26FA}',                         # ⛺
    '\u{26FD}',                         # ⛽
    '\u{2705}',                         # ✅
    '\u{270A}', '\u{270B}',             # ✊✋
    '\u{2728}',                         # ✨
    '\u{274C}',                         # ❌
    '\u{274E}',                         # ❎
    '\u{2753}', '\u{2755}',             # ❓❕
    '\u{2757}',                         # ❗
    '\u{2795}', '\u{2797}',             # ➕➗
    '\u{27B0}',                         # ➰
    '\u{27BF}',                         # ➿
  }.each do |ch|
    it "measures U+#{ch.ord.to_s(16).upcase} as 2 columns" do
      Crysterm::Unicode.codepoint_width(ch).should eq 2
    end
  end

  # The binary search in `wide?` relies on the table being sorted and
  # non-overlapping; the inserts must not break that.
  it "keeps the WIDE table sorted and non-overlapping" do
    tbl = Crysterm::Unicode::WIDE
    tbl.each { |r| r[0].should be <= r[1] }
    tbl.each_cons(2) do |(a, b)|
      # Each range must start strictly after the previous range ends.
      b[0].should be > a[1]
    end
  end

  # A codepoint NOT in the gap list stays narrow (guards against an over-broad
  # range insert).
  it "leaves a non-wide codepoint in the gap at width 1" do
    Crysterm::Unicode.codepoint_width('\u{2700}').should eq 1 # black safety scissors (not EAW-W)
  end
end

# ---------------------------------------------------------------------------
# Finding 11: a width-2 grapheme whose lead lands at x == -1 (clipped by the
# left screen edge) must not leave an orphan continuation at column 0.
# ---------------------------------------------------------------------------
describe "BUGS-F1 #11: wide glyph straddling the left screen edge" do
  it "blanks column 0 instead of stamping an orphan continuation" do
    s, _ = fu_screen(6, 1)
    # left: -1 → the widget's content column 0 (the wide glyph's lead) maps to
    # screen column -1 (clipped), so its continuation would land at screen col 0.
    Widget::Box.new parent: s, top: 0, left: -1, width: 4, height: 1,
      content: "漢AB"
    s._render
    line = s.lines[0]

    # Column 0 must be a plain blank, never a continuation with no lead anywhere
    # (which would leave col 0 unrepainted forever and shift the row left).
    line[0].continuation?.should be_false
    line[0].char.should eq ' '
    line[0].grapheme_overlay.should be_nil
  end
end

# ---------------------------------------------------------------------------
# Finding 10: in `#draw`, a changed continuation cell whose lead is unchanged
# must not let the next changed cell assume the cursor advanced.
# ---------------------------------------------------------------------------
describe "BUGS-F1 #10: changed continuation cell in the draw diff" do
  it "repositions absolutely for the next changed cell (no left shift)" do
    s, outio = fu_screen(6, 1)
    line = s.lines[0]

    da = Crysterm::Window::DEFAULT_ATTR
    # Baseline: wide lead at col 0, its continuation at col 1, a letter at col 2.
    line[0].attr = da
    line[0].grapheme = "中"
    line[1].continuation!
    line[2].attr = da
    line[2].char = 'Y'
    line[0].width.should eq 2 # sanity
    line.dirty = true
    s.draw # sync @flushed_lines to @lines

    # Now change ONLY the continuation cell's attr (lead stays byte-identical)
    # and the letter cell's char. The continuation is reached WITHOUT skip_next
    # because its unchanged lead is skipped by the diff.
    line[1].attr = da ^ Crysterm::Attr::REVERSE
    line[2].char = 'Z'
    line.mark_dirty 1
    line.mark_dirty 2
    line.dirty = true

    outio.clear
    s.draw
    emitted = outio.to_s

    emitted.should contain 'Z'
    # The 'Z' cell (screen column 2, 1-based column 3) must be repositioned to
    # absolutely — otherwise it prints one column too far left. The absolute
    # cursor move to column 3 is the fix's signature; without it there is no
    # reposition before 'Z' at all.
    idx = emitted.index!('Z')
    emitted[0, idx].should contain ";3H"
  end
end

# ---------------------------------------------------------------------------
# Finding 28: Plane#composite_onto must reconcile a grapheme-overlay difference
# even when attr and base codepoint are identical.
# ---------------------------------------------------------------------------
describe "BUGS-F1 #28: plane fold installs a grapheme overlay under a matching base" do
  it "installs an accented cluster over a matching base 'e'" do
    plane = Crysterm::Plane.new(z: 1, width: 3, height: 1)
    a = Crysterm::Window::DEFAULT_ATTR # fully-opaque overlay attr

    # Overlay paints "é" (base codepoint 'e' + combining accent).
    prow = plane.cells[0]
    prow.attrs[0] = a
    prow.chars[0] = 'e'
    prow.set_grapheme 0, "é"
    prow.dirty = true
    prow.has_graphemes?.should be_true

    # Base already shows a bare 'e' with the SAME composited attr and NO cluster,
    # so the old attr/base-char change test sees "equal" and would skip the fold.
    base = [Crysterm::Window::Row.new(3)]
    3.times { base[0].push a, ' ' }
    base[0].attrs[0] = Crysterm::Colors.composite(a, a)
    base[0].chars[0] = 'e'
    base[0].grapheme_at?(0).should be_nil # no cluster yet

    plane.composite_onto base

    # The accent must be installed despite the matching attr/base char.
    base[0].grapheme_at?(0).should eq "é"
  end
end
