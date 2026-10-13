require "./spec_helper"

include Crysterm

# `media.backend: none` draws none of the images Crysterm resolves itself:
# a `TextEdit`'s block images are neither fetched, decoded nor drawn — an
# image with a title shows the picture glyph and the title in the picture's
# place — and a CSS `background-image` is not painted. What asks
# `Media.resolve` for its own backend gets Auto's pick.

private IMAGE_DIR = File.expand_path("#{__DIR__}/../data/image")

private def none_screen(w = 40, h = 8)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

private def none_browser(s, markdown : String) : Widget::TextBrowser
  tb = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: s.awidth, height: s.aheight
  tb.document.base_url = IMAGE_DIR
  tb.set_markdown markdown
  s.repaint
  tb
end

# Row *y* of the window as text, a cluster's lead char for the cluster,
# its continuation cell dropped, trailing blanks dropped.
private def screen_row(s, y : Int32) : String
  String.build { |io| s.cell_rows[y].each { |c| io << c.char unless c.char == '\0' } }.rstrip
end

# The picture glyph as `screen_row` reads it: its lead char.
private def icon : Char
  Glyphs.str(Glyphs::Role::IconImage, Glyphs::Tier::Extended)[0]
end

# Runs the block with `media.backend` at None, put back after.
private def with_none(&)
  Crysterm::Config.media_backend = Widget::Media::Backend::None
  yield
ensure
  Crysterm::Config.reset "media.backend"
end

describe "Widget::Media::Backend::None" do
  it "is a choice with a label that pins no type and needs nothing of the terminal" do
    Widget::Media::Backend.parse("none").should eq Widget::Media::Backend::None
    Widget::Media::Backend::None.label.should eq "None"
    Widget::Media::Backend::None.type.should be_nil
    Widget::Media::Backend::None.family.should be_nil
    Widget::Media::Backend::None.available?.should be_true
  end

  it "disables Crysterm's own media and leaves resolve at Auto's pick" do
    s = none_screen
    auto = Widget::Media.resolve(Widget::Media::Content::Image, s.tput)
    Widget::Media.disabled?.should be_false
    with_none do
      Widget::Media.disabled?.should be_true
      Widget::Media.resolve(Widget::Media::Content::Image, s.tput).should eq auto
      Widget::Media.resolve(Widget::Media::Content::Painter, s.tput).should eq Widget::Media.auto_type(Widget::Media::Content::Painter, s.tput)
    end
    s.destroy
  end

  it "paints no background image, and paints it again when switched back" do
    s = none_screen(80, 24)
    begin
      box = Widget::Box.new parent: s, top: 0, left: 0, width: 12, height: 6, content: "Hi"
      box.style.background_image = File.join(IMAGE_DIR, "matterhorn.png")
      s.repaint
      box.background_media.should_not be_nil
      with_none do
        s.repaint
        box.background_media.should be_nil
        s.repaint
        box.background_media.should be_nil
      end
      s.repaint
      box.background_media.should_not be_nil
    ensure
      s.destroy
    end
  end

  it "shows a block image's title in the picture's place, fetching and decoding nothing" do
    fetched = [] of String
    saved = Widget::Media.fetcher
    Widget::Media.fetcher = ->(url : String) { fetched << url; raise "offline" }
    s = none_screen
    begin
      with_none do
        tb = none_browser s, "![Matterhorn](matterhorn.png \"The Matterhorn\")\n\n![Far](https://example.com/far.png \"Far away\")\n\nAfter"
        tb.block_media.should be_empty
        fetched.should be_empty
        screen_row(s, 0).should eq "#{icon} The Matterhorn"
        screen_row(s, 1).should eq "#{icon} Matterhorn"
        screen_row(s, 3).should eq "#{icon} Far away"
        screen_row(s, 4).should eq "#{icon} Far"
        screen_row(s, 6).should eq "After"
        # The title row holds no positions: the caret is on the caption.
        tb.cursor_position = 0
        tb.cursor_viewport_row.should eq 1
      end
      fetched.should be_empty
    ensure
      Widget::Media.fetcher = saved
      s.destroy
    end
  end

  it "shows an image without a title, or with its alt text for one, as its caption alone" do
    s = none_screen
    with_none do
      tb = none_browser s, "![Matterhorn](matterhorn.png)\n\n![Peak](matterhorn.png \"Peak\")\n\nAfter"
      tb.block_media.should be_empty
      screen_row(s, 0).should eq "#{icon} Matterhorn"
      screen_row(s, 2).should eq "#{icon} Peak"
      screen_row(s, 4).should eq "After"
    end
    s.destroy
  end

  it "wraps a long title to the text width" do
    s = none_screen(20, 8)
    with_none do
      none_browser s, "![M](matterhorn.png \"A very long title for a picture\")"
      screen_row(s, 0).should start_with "#{icon} A very long"
      screen_row(s, 1).should_not be_empty
      screen_row(s, 1).should_not contain icon
      (0..3).map { |y| screen_row(s, y) }.should contain "#{icon} M"
    end
    s.destroy
  end

  it "shows no title with images off" do
    s = none_screen
    with_none do
      tb = none_browser s, "![Matterhorn](matterhorn.png \"The Matterhorn\")"
      tb.images_enabled = false
      s.repaint
      screen_row(s, 0).should eq "#{icon} Matterhorn"
    end
    s.destroy
  end

  it "lays the images out again when switched into and out of None at run time" do
    s = none_screen
    tb = none_browser s, "![Matterhorn](matterhorn.png \"The Matterhorn\")\n\nAfter"
    tb.block_media.size.should eq 1
    picture_rows = tb.scroll_height
    with_none do
      s.repaint
      tb.block_media.should be_empty
      screen_row(s, 0).should eq "#{icon} The Matterhorn"
      tb.scroll_height.should eq 1 + 1 + 1 + 1 # title, caption, margin, After
    end
    s.repaint
    tb.block_media.size.should eq 1
    tb.scroll_height.should eq picture_rows
    s.destroy
  end

  it "starts under None and draws the pictures once switched away" do
    s = none_screen
    tb = with_none do
      none_browser s, "![Matterhorn](matterhorn.png \"The Matterhorn\")"
    end
    tb.block_media.should be_empty
    s.repaint
    tb.block_media.size.should eq 1
    s.destroy
  end
end
