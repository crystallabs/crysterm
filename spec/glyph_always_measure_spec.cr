require "./spec_helper"

include Crysterm

# The pragmatic "always-measure" cell path (GLYPHS.md §4/§5): the *single-
# placement* affordance roles — the non-`cell?` glyphs a widget paints once
# into a box it can size (`SizeGrip`, `DockWidget`'s close/float buttons) —
# keep a wide or multi-codepoint override whole and reserve its measured width,
# instead of the reject-to-1-column `Char` that the fill-region cell roles
# (scrollbar/slider/rules) must stay on. Unstyled/narrow stays byte-identical.
private def am_screen(width = 80, height = 24)
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: width,
    height: height,
    default_quit_keys: false)
end

describe "Widget#glyph_measured (always-measure single-placement path)" do
  it "keeps a wide CSS override whole and reports its measured width" do
    s = am_screen
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 1
    st = Style.new
    st.glyph = "⚠️" # U+26A0 + VS16 — 2 codepoints, 2 columns
    g, w = b.glyph_measured(Glyphs::Role::SizeGrip, st)
    g.should eq "⚠️"
    w.should eq 2
  end

  it "resolves the registry glyph at width 1 when unstyled (byte-identical)" do
    s = am_screen
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 1
    g, w = b.glyph_measured(Glyphs::Role::SizeGrip, nil)
    g.should eq Glyphs.str(Glyphs::Role::SizeGrip, Glyphs::Tier::Unicode)
    w.should eq 1
  end

  it "falls back to the registry (not omit) for CSS `glyph: none`, like #glyph" do
    s = am_screen
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 1
    st = Style.new
    st.glyph = Glyphs::NONE_STR
    g, w = b.glyph_measured(Glyphs::Role::SizeGrip, st)
    g.should eq Glyphs.str(Glyphs::Role::SizeGrip, Glyphs::Tier::Unicode)
    w.should eq 1
  end
end

describe "SizeGrip always-measure width reservation" do
  it "grows to a wide glyph's measured width, keeping the grapheme whole" do
    s = am_screen
    win = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 6
    grip = Widget::SizeGrip.new parent: win, bottom: 0, right: 0,
      width: 1, height: 1, glyph: "⚠️"
    s._render
    grip.content.should eq "⚠️" # whole 2-codepoint cluster, not reduced
    grip.width.should eq 2      # reserved the measured columns (grew from 1)
  end

  it "stays 1 column for the classic single-cell glyph (byte-identical)" do
    s = am_screen
    win = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 6
    grip = Widget::SizeGrip.new parent: win, bottom: 0, right: 0, width: 1, height: 1
    s._render
    grip.width.should eq 1
    grip.content.should eq Glyphs.str(Glyphs::Role::SizeGrip, Glyphs::Tier::Unicode)
  end

  it "never shrinks a grip wider than its glyph" do
    s = am_screen
    win = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 6
    grip = Widget::SizeGrip.new parent: win, bottom: 0, right: 0, width: 4, height: 1
    s._render
    grip.width.should eq 4 # `awidth (4) < w (1)` is false — left alone
  end
end

describe "DockWidget titlebuttons reserve the glyph's measured width" do
  it "sizes the close button to a wide registry glyph and offsets the float button past it" do
    Glyphs.set Glyphs::Role::CloseButton, unicode: "⚠️" # 2 columns
    begin
      s = am_screen
      dock = Widget::DockWidget.new parent: s, top: 0, left: 0, width: 30, height: 10,
        title: "Files", closable: true, floatable: true
      s._render
      close = dock.@close_button.not_nil!
      float = dock.@float_button.not_nil!
      close.width.should eq 2      # reserved the wide glyph's columns
      close.content.should eq "⚠️" # kept whole
      # Float button sits one cell left of the (2-wide) close button.
      float.right.should eq 3 # Unicode.width(close_glyph) + 1
    ensure
      Glyphs.reset
    end
  end

  it "keeps single-cell buttons 1 column wide when unstyled (byte-identical)" do
    s = am_screen
    dock = Widget::DockWidget.new parent: s, top: 0, left: 0, width: 30, height: 10,
      title: "Files", closable: true, floatable: true
    s._render
    dock.@close_button.not_nil!.width.should eq 1
    dock.@float_button.not_nil!.right.should eq 2 # classic 1 + 1 gap
  end
end
