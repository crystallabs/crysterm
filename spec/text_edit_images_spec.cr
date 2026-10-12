require "./spec_helper"
require "base64"

include Crysterm

# Block images: the Markdown importer records a paragraph that is one image
# on its block (`TextBlockFormat#image`), the exporter writes it back, the
# document resolves image names against its `base_url`, and `TextEdit`
# reserves rows for the picture and owns a `Media` child drawing it
# (`text_edit/images.cr`).

private IMAGE_DIR = File.expand_path("#{__DIR__}/../data/image")
private IMAGE     = File.join(IMAGE_DIR, "matterhorn.png") # 240 × 84 pixels

# A 30 × 20 pixel PNG (a flat red rectangle): smaller than any text column.
private SMALL_PNG = Base64.decode("iVBORw0KGgoAAAANSUhEUgAAAB4AAAAUCAYAAACaq43EAAAAJUlEQVR42mM4ISf3fyAww6jFoxaPWjxq8ajFoxaPWjxq8cixGACyL7dFCHooGgAAAABJRU5ErkJggg==")

# Yields the path of a copy of `SMALL_PNG` on disk, deleted after.
private def with_small_png(&)
  path = File.tempname("text-edit-images-small", ".png")
  File.write path, SMALL_PNG
  yield path
ensure
  File.delete? path if path
end

private def headless_screen(w = 40, h = 8)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

# A browser filling the window, showing *markdown* with image names counted
# from the test images' directory.
private def browser_with(s, markdown : String) : Widget::TextBrowser
  tb = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: s.awidth, height: s.aheight
  tb.document.base_url = IMAGE_DIR
  tb.set_markdown markdown
  s.repaint
  tb
end

private def placeholder : String
  Glyphs.str(Glyphs::Role::IconImage, Glyphs::Tier::Extended)
end

describe "TextMarkdown block images" do
  it "records a paragraph that is one image on its block, the text staying the placeholder and the alt text" do
    doc = TextDocument.from_markdown("![Alt text](pic.png \"A title\")\n\nAfter")
    img = doc.blocks[0].block_format.image.should_not be_nil
    img.name.should eq "pic.png"
    img.alt.should eq "Alt text"
    img.title.should eq "A title"
    doc.blocks[0].text.should eq "#{placeholder} Alt text"
    doc.blocks[1].block_format.image.should be_nil
    doc.blocks[1].text.should eq "After"
  end

  it "takes an image wrapped in a link, surrounded by whitespace, as a block image too" do
    doc = TextDocument.from_markdown("  [![badge](b.svg)](https://ci.example)  ")
    img = doc.blocks[0].block_format.image.should_not be_nil
    img.name.should eq "b.svg"
    img.alt.should eq "badge"
    img.title.should be_nil
    doc.blocks[0].fragments.any? { |f| f.format.anchor_href == "https://ci.example" }.should be_true
  end

  it "leaves an image among text inline" do
    doc = TextDocument.from_markdown("see ![a](b.png) here\n\n![x](y.png) and ![z](w.png)")
    doc.blocks[0].block_format.image.should be_nil
    doc.blocks[0].text.should eq "see #{placeholder} a here"
    doc.blocks[1].block_format.image.should be_nil
  end

  it "exports a block image as the image, in a list item too" do
    src = "![Alt text](pic.png \"A title\")\n\nAfter\n\n- ![item](<a b.png>)\n- plain"
    doc = TextDocument.from_markdown(src)
    text = doc.to_markdown
    text.should contain "![Alt text](pic.png \"A title\")"
    text.should contain "- ![item](a%20b.png)" # markd percent-encodes the destination
    again = TextDocument.from_markdown(text)
    again.blocks[0].block_format.image.should eq doc.blocks[0].block_format.image
    again.blocks.find!(&.block_format.list_format).block_format.image.try(&.name).should eq "a%20b.png"
    # A linked block image keeps its link.
    TextDocument.from_markdown("[![badge](b.svg)](https://ci.example)").to_markdown.should eq "[![badge](b.svg)](https://ci.example)"
  end
end

describe "TextDocument#base_url" do
  it "resolves relative names against a directory, a file: URL or a URL base, and leaves the rest alone" do
    doc = TextDocument.new
    doc.resolve_url("pic.png").should eq "pic.png"
    # No base: still a path, so the parser's percent-encoding comes off.
    doc.resolve_url("%C4%87evapi.png").should eq "ćevapi.png"
    doc.resolve_url("sub/a%20b.png").should eq "sub/a b.png"
    doc.base_url = "/tmp/docs/sub"
    doc.resolve_url("pic.png").should eq "/tmp/docs/sub/pic.png"
    doc.resolve_url("../a%20b.png").should eq "/tmp/docs/a b.png"
    doc.resolve_url("/abs/pic.png").should eq "/abs/pic.png"
    doc.resolve_url("https://example.com/x.png").should eq "https://example.com/x.png"
    doc.resolve_url("file:///other/c%20d.png").should eq "/other/c d.png"
    doc.base_url = "file:///tmp/f/"
    doc.resolve_url("pic.png").should eq "/tmp/f/pic.png"
    doc.base_url = "https://example.com/docs/readme.md"
    doc.resolve_url("img/a.png").should eq "https://example.com/docs/img/a.png"
  end

  it "survives a whole-content replacement" do
    doc = TextDocument.from_markdown("one")
    doc.base_url = "/tmp/docs"
    doc.set_markdown "two"
    doc.base_url.should eq "/tmp/docs"
  end
end

describe "TextEdit block images" do
  it "reserves the picture's rows, capped at half the viewport, and owns a Media child for the picture" do
    s = headless_screen
    tb = browser_with s, "![Matterhorn](matterhorn.png)\n\nAfter"
    # 240 × 84 pixels over the 10 × 20 fallback cell is 24 × 4.2 cells; the
    # cap is half of 8, and the width shrinks with it: 24 × 4 / 4.2.
    tb.scroll_height.should eq 4 + 1 + 1 + 1 # picture, caption, margin, After
    media = tb.block_media
    media.size.should eq 1
    media[0].file.should eq IMAGE
    media[0].should be_a(Widget::Media::Cells)
    media[0].aheight.should eq 4
    media[0].awidth.should eq 23
    media[0].atop.should eq 0
    media[0].fit.should eq Widget::Media::Fit::Contain
    media[0].visible?.should be_true
    # The caption row holds the block's positions; the picture rows none.
    tb.cursor_position = 0
    tb.cursor_viewport_row.should eq 4
    s.destroy
  end

  it "draws a small picture at its natural size rather than stretched to the column" do
    s = headless_screen
    with_small_png do |small|
      tb = browser_with s, "![icon](#{small})\n\nAfter"
      # 30 × 20 pixels over the 10 × 20 fallback cell: 3 columns, 1 row.
      tb.block_media.size.should eq 1
      tb.block_media[0].awidth.should eq 3
      tb.block_media[0].aheight.should eq 1
      tb.scroll_height.should eq 1 + 1 + 1 + 1 # picture, caption, margin, After
    end
    s.destroy
  end

  it "shrinks a picture wider than the text column to fit it, keeping its aspect" do
    s = headless_screen(12, 8)
    tb = browser_with s, "![Matterhorn](matterhorn.png)\n\nAfter"
    # 24 × 4.2 cells naturally, halved to the 12 columns: 12 × 2.
    tb.block_media[0].awidth.should eq 12
    tb.block_media[0].aheight.should eq 2
    tb.scroll_height.should eq 2 + 2 + 1 + 1 # picture, the caption wrapped in two, margin, After
    s.destroy
  end

  it "measures in the cell size the terminal reports, and again when it changes" do
    s = headless_screen
    s.screen.cell_pixel_width = 5
    s.screen.cell_pixel_height = 10
    with_small_png do |small|
      tb = browser_with s, "![icon](#{small})\n\nAfter"
      tb.block_media[0].awidth.should eq 6
      tb.block_media[0].aheight.should eq 2
      # A zoom re-probes the cell size with the key, the document and the
      # cap unchanged: the pictures alone bring the relayout.
      s.screen.cell_pixel_width = 10
      s.screen.cell_pixel_height = 20
      s.repaint
      tb.block_media[0].awidth.should eq 3
      tb.block_media[0].aheight.should eq 1
    end
    s.destroy
  end

  it "drops the rows and the children when images are off, and brings them back" do
    s = headless_screen
    tb = browser_with s, "![Matterhorn](matterhorn.png)\n\nAfter"
    tb.images_enabled = false
    s.repaint
    tb.images_enabled?.should be_false
    tb.scroll_height.should eq 3
    tb.block_media.should be_empty
    tb.images_enabled = true
    s.repaint
    tb.scroll_height.should eq 7
    tb.block_media.size.should eq 1
    s.destroy
  end

  it "honors max_image_rows" do
    s = headless_screen
    tb = browser_with s, "![Matterhorn](matterhorn.png)\n\nAfter"
    tb.max_image_rows = 2
    s.repaint
    tb.scroll_height.should eq 5
    tb.block_media[0].aheight.should eq 2
    tb.block_media[0].awidth.should eq 11
    s.destroy
  end

  it "shows a missing or undecodable image as its caption alone, without raising" do
    s = headless_screen
    bad = File.tempname("text-edit-images", ".png")
    File.write bad, "not a picture"
    begin
      tb = browser_with s, "![gone](nowhere.png)\n\n![bad](#{bad})\n\nAfter"
      tb.scroll_height.should eq 5
      tb.block_media.should be_empty
      tb.document.blocks[0].text.should eq "#{placeholder} gone"
    ensure
      File.delete? bad
      s.destroy
    end
  end

  it "destroys a child whose picture scrolled out of view and rebuilds it on the way back, keeping a clipped one" do
    s = headless_screen
    tb = browser_with s, "![Matterhorn](matterhorn.png)\n\n" + (1..30).map { |i| "Paragraph #{i}" }.join("\n\n")
    first = tb.block_media[0]
    tb.scroll_to 2 # the picture's top two rows above the viewport
    s.repaint
    tb.block_media.size.should eq 1
    tb.block_media[0].should be(first)
    tb.block_media[0].visible?.should be_true
    tb.scroll_to 20
    s.repaint
    tb.block_media.should be_empty
    tb.scroll_to 0
    s.repaint
    tb.block_media.size.should eq 1
    tb.block_media[0].should_not be(first)
    s.destroy
  end

  it "keeps the child across a re-render of the same source and rebuilds it for a new media backend" do
    s = headless_screen
    tb = browser_with s, "![Matterhorn](matterhorn.png)\n\nAfter"
    first = tb.block_media[0]
    tb.set_markdown "Intro\n\n![Matterhorn](matterhorn.png)\n\nAfter", keep_view: true
    s.repaint
    tb.block_media.size.should eq 1
    tb.block_media[0].should be(first)
    tb.block_media[0].atop.should eq 2 # below "Intro" and its margin
    begin
      Crysterm::Config.media_backend = Widget::Media::Backend::AnsiC16
      s.repaint
      tb.block_media.size.should eq 1
      tb.block_media[0].should be_a(Widget::Media::Ascii::C16)
      tb.block_media[0].should_not be(first)
    ensure
      Crysterm::Config.reset "media.backend"
    end
    s.destroy
  end

  it "takes a streamed image in" do
    s = headless_screen
    tb = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: 40, height: 8
    tb.document.base_url = IMAGE_DIR
    tb.append_markdown "Intro\n\n![Matterhorn](matt"
    tb.append_markdown "erhorn.png)\n\nTail"
    tb.flush_markdown
    s.repaint
    tb.block_media.size.should eq 1
    tb.scroll_height.should eq 1 + 1 + 4 + 1 + 1 + 1
    s.destroy
  end

  it "re-caps the picture when only the viewport's height changes" do
    s = headless_screen
    tb = browser_with s, "![Matterhorn](matterhorn.png)\n\nAfter"
    tb.block_media[0].aheight.should eq 4
    # Half of the 4 rows left: the layout key (the width's) and the document
    # are unchanged, so the cap alone must bring the relayout.
    tb.height = 4
    s.repaint
    tb.block_media[0].aheight.should eq 2
    tb.scroll_height.should eq 2 + 1 + 1 + 1
    tb.height = 8
    s.repaint
    tb.block_media[0].aheight.should eq 4
    s.destroy
  end

  # A remote image's share of a replacement: text_edit_remote_image_retry_spec.cr.
  it "measures a local file again after a whole-content replacement" do
    s = headless_screen
    tb = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: s.awidth, height: s.aheight
    tb.document.base_url = IMAGE_DIR
    tb.set_markdown "![Matterhorn](matterhorn.png)"
    s.repaint
    tb.@image_sizes.has_key?(IMAGE).should be_true
    tb.set_markdown "![Matterhorn](matterhorn.png)\n\nmore"
    tb.@image_sizes.has_key?(IMAGE).should be_false
    s.repaint
    tb.@image_sizes.has_key?(IMAGE).should be_true
    tb.block_media.size.should eq 1
    s.destroy
  end
end
