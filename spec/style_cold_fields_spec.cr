require "./spec_helper"

# The rarely-set `Style` fields live in a lazily-created `Style::Cold` side
# object, so a plain style (what every widget starts with) is a fraction of
# the size and its dup copies that much less.
describe "Style cold side object" do
  it "is absent on a fresh style and the accessors report their defaults" do
    st = Crysterm::Style.new(fg: "red", border: true)
    st.@cold.should be_nil
    st.glyph.should be_nil
    st.glyph_for(Crysterm::Glyphs::Tier::Unicode).should be_nil
    st.title.same?(st).should be_true
    st.title?.should be_nil
    st.scrollbar.same?(st).should be_true
    st.alternate_row.same?(st).should be_true
    st.alternate_row?.should be_false
    st.alternate_background_color.should be_nil
    st.offset_x.should eq 0
    st.offset_y.should eq 0
    st.offset?.should be_false
    st.offset_left.should be_nil
    st.background_image.should be_nil
    st.background_size.should eq Crysterm::Style::BackgroundSize::Cover
    st.transitions.should be_nil
    st.animation.should be_nil
    st.gridline_color.should be_nil
    st.light.should be_nil
    st.look.should be_nil
    st.specified?(:glyph).should be_false
    st.specified?(:light).should be_false
    st.specified?(:offset_left).should be_false
  end

  it "clearing a cold field on a style without the side object allocates nothing" do
    st = Crysterm::Style.new
    st.glyph = nil
    st.title = nil
    st.offsets = nil
    st.light = nil
    st.look = nil
    st.gridline_color = nil
    st.@cold.should be_nil
  end

  it "materializes on the first write and reads back through the accessors" do
    st = Crysterm::Style.new
    st.glyph_unicode = "★"
    st.@cold.should_not be_nil
    st.glyph_for(Crysterm::Glyphs::Tier::Extended).should eq "★"
    st.glyph_for(Crysterm::Glyphs::Tier::Ascii).should be_nil
    st.specified?(:glyph_unicode).should be_true
    sub = Crysterm::Style.new(fg: "blue")
    st.title = sub
    st.title.same?(sub).should be_true
    st.title?.same?(sub).should be_true
    st.sub_style("title").same?(sub).should be_true
    st.raw_sub_style("title").same?(sub).should be_true
    st.raw_sub_style("pane").should be_nil
    st.offset_left = 2
    st.offset_x.should eq 2
    st.offset_right = 1
    st.offset_x.should eq 2 # `left` wins when given
    st.offsets = nil
    st.offset?.should be_false
    st.offsets = 3
    st.offset_y.should eq 3
    st.light = :ne
    st.light.should_not be_nil
    st.look = :raised
    st.look.should eq Crysterm::Style::Look::Raised
    st.gridline_color = "#ff0000"
    st.gridline_color.should eq 0xff0000
    st.background_size = Crysterm::Style::BackgroundSize::Contain
    st.background_size.should eq Crysterm::Style::BackgroundSize::Contain
    st.specified?(:background_size).should be_true
  end

  it "takes the sub-style and glyph constructor arguments" do
    ind = Crysterm::Style.new(fg: "green")
    st = Crysterm::Style.new(indicator: ind, glyph: "x", glyph_open: "[", alternate_row: ind)
    st.indicator.same?(ind).should be_true
    st.glyph.should eq "x"
    st.glyph_open.should eq "["
    st.alternate_row.same?(ind).should be_true
    st.alternate_row?.should be_true
  end

  it "shares the side object with a dup until either side writes a cold field" do
    sub = Crysterm::Style.new(fg: "blue")
    st = Crysterm::Style.new(title: sub, glyph: "x")
    copy = st.dup
    copy.@cold.same?(st.@cold).should be_true
    copy.title.same?(sub).should be_true
    copy.glyph.should eq "x"
    copy.title = Crysterm::Style.new(fg: "red")
    copy.@cold.same?(st.@cold).should be_false
    st.title.same?(sub).should be_true
    st.glyph = "y"
    copy.glyph.should eq "x"
    # Clearing through a still-shared side object unshares it too.
    other = st.dup
    other.glyph = nil
    other.glyph.should be_nil
    st.glyph.should eq "y"
    # The original writing first leaves the copy untouched as well.
    third = st.dup
    st.offsets = 2
    third.offset?.should be_false
    st.offset_x.should eq 2
  end

  it "composes the alternate row from the bg override and drops the memo on change" do
    st = Crysterm::Style.new(fg: "white")
    st.alternate_background_color = "#102030"
    st.alternate_row?.should be_true
    st.alternate_background_color.should eq 0x102030
    row = st.alternate_row
    row.bg.should eq 0x102030
    row.fg.should eq st.fg
    st.alternate_row.same?(row).should be_true
    st.fg = "yellow"
    st.alternate_row.fg.should eq st.fg
    st.alternate_row = nil
    st.alternate_row.bg.should eq 0x102030 # the override alone still composes
  end

  it "folds an inline style's sub-styles" do
    inline = Crysterm::Style.new(title: Crysterm::Style.new(fg: "red"))
    inline.alternate_background_color = "#000001"
    st = Crysterm::Style.new
    st.fold_inline_sub_styles inline
    st.title?.same?(inline.title?).should be_true
    st.alternate_background_color.should eq 0x000001
    Crysterm::Style.new.fold_inline_sub_styles Crysterm::Style.new
  end

  it "keeps a plain style small" do
    instance_sizeof(Crysterm::Style).should be < 400
  end
end
