require "./spec_helper"

include Crysterm

private def headless_screen
  Crysterm::Screen.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: 24)
end

# A real PNG shipped in the repo, decoded by the pure-Crystal PNGGIF reader.
private def bg_image_path
  "#{__DIR__}/../data/image/matterhorn.png"
end

# Runs *block* with `image.exclude` set to *value*, restoring it afterward, so a
# rendering test can force a particular backend without leaking global config.
private def with_media_exclude(value : String, &)
  orig = Crysterm::Config.media_exclude
  Crysterm::Config.media_exclude = value
  begin
    yield
  ensure
    Crysterm::Config.media_exclude = orig
  end
end

describe "CSS background-image" do
  describe "parsing" do
    it "extracts the url from the background-image longhand" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "background-image", %{url("pics/bg.png")})
      s.background_image.should eq "pics/bg.png"
    end

    it "extracts both color and image from the background shorthand" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "background", %{red url('a/b.png') center})
      s.background_image.should eq "a/b.png"
      s.bg.should_not be_nil
    end

    it "resets the image when the shorthand carries no url (CSS reset semantics)" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "background-image", "url(x.png)")
      Crysterm::CSS::Properties.apply(s, "background", "blue")
      s.background_image.should be_nil
    end

    it "drops a blank background shorthand instead of clearing the image (invalid-declaration)" do
      # A collapsed undefined `var(--x)` reaches here as "". Per CSS this invalid
      # declaration is dropped, leaving any previously-cascaded background-image
      # intact — not reset as a genuine no-`url(...)` shorthand would.
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "background-image", "url(x.png)")
      Crysterm::CSS::Properties.apply(s, "background", "")
      s.background_image.should eq "x.png"
    end

    it "clears the image on `background-image: none`" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "background-image", "url(x.png)")
      Crysterm::CSS::Properties.apply(s, "background-image", "none")
      s.background_image.should be_nil
    end

    it "parses a background-size keyword" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "background-size", "contain")
      s.background_size.should eq Style::BackgroundSize::Contain
    end

    it "maps `100% 100%` to Stretch" do
      s = Style.new
      Crysterm::CSS::Properties.apply(s, "background-size", "100% 100%")
      s.background_size.should eq Style::BackgroundSize::Stretch
    end

    it "recognizes the new properties as known" do
      Crysterm::CSS::Properties.known?("background-image").should be_true
      Crysterm::CSS::Properties.known?("background-size").should be_true
    end
  end

  describe "Style fields" do
    it "tracks background_image as specified only when set" do
      Style.new.specified?(:background_image).should be_false
      s = Style.new
      s.background_image = "x.png"
      s.specified?(:background_image).should be_true
    end

    it "defaults background_size to Cover, unspecified" do
      s = Style.new
      s.background_size.should eq Style::BackgroundSize::Cover
      s.specified?(:background_size).should be_false
    end

    it "tracks background_size as specified once assigned" do
      s = Style.new
      s.background_size = Style::BackgroundSize::Cover
      s.specified?(:background_size).should be_true
    end
  end

  describe "Media::Kitty background placement" do
    it "maps `background=` onto a negative z and back" do
      k = Widget::Media::Kitty.new file: "x.png", parent: headless_screen
      k.background?.should be_false
      k.z.should be_nil

      k.background = true
      k.z.should eq(-1)
      k.background?.should be_true

      k.background = false
      k.z.should be_nil
      k.background?.should be_false
    end
  end

  describe "backend resolution" do
    it "resolves a background to a cell-grid backend, honoring image.exclude" do
      s = headless_screen
      with_media_exclude("kitty,glyph") do
        Widget::Media.resolve(Widget::Media::Content::Background, s.tput)
          .should eq Widget::Media::Type::Ansi
      end
    end
  end

  describe "rendering with a cell-grid backend" do
    it "paints the image into empty cells with the text drawn on top" do
      with_media_exclude("kitty") do
        s = headless_screen
        box = Widget::Box.new parent: s, top: 0, left: 0, width: 12, height: 6, content: "Hi"
        box.style.background_image = bg_image_path
        s._render

        box.background_media.should_not be_nil
        box.background_media.is_a?(Widget::Media::Cells).should be_true
        box.background_paints_cells?.should be_true

        # An empty cell (well away from the "Hi") carries an image color.
        Crysterm::Attr.bg(s.lines[3][5].attr).should_not eq Crysterm::Attr::COLOR_DEFAULT

        # The content glyphs survive on top of the image.
        s.lines[0][0].char.should eq 'H'
        s.lines[0][1].char.should eq 'i'

        # Nearly every cell of the box carries the image (all but the two text cells).
        painted = 0
        (0...6).each do |y|
          (0...12).each do |x|
            painted += 1 if Crysterm::Attr.bg(s.lines[y][x].attr) != Crysterm::Attr::COLOR_DEFAULT
          end
        end
        painted.should be >= 60
      end
    end

    it "grades the content over the background with style.alpha" do
      with_media_exclude("kitty") do
        s = headless_screen
        box = Widget::Box.new parent: s, top: 0, left: 0, width: 12, height: 6, content: "Hi"
        box.style.background_image = bg_image_path
        box.style.alpha = 0.5
        s._render

        # With alpha the text cell blends over the image, so its background is an
        # image-derived color rather than the terminal default.
        hcell = s.lines[0][0]
        hcell.char.should eq 'H'
        Crysterm::Attr.bg(hcell.attr).should_not eq Crysterm::Attr::COLOR_DEFAULT
      end
    end

    it "creates no background layer when no background-image is set" do
      s = headless_screen
      box = Widget::Box.new parent: s, top: 0, left: 0, width: 8, height: 3, content: "hi"
      s._render

      box.background_media.should be_nil
      box.background_paints_cells?.should be_false
      # Normal rendering is unaffected.
      s.lines[0][0].char.should eq 'h'
    end

    it "tears the background layer down when the image is cleared" do
      with_media_exclude("kitty") do
        s = headless_screen
        box = Widget::Box.new parent: s, top: 0, left: 0, width: 8, height: 3, content: "hi"
        box.style.background_image = bg_image_path
        s._render
        box.background_media.should_not be_nil

        # Clearing the property and re-rendering the widget tears the layer down.
        # (Rendered directly: the screen's damage tracking skips a clean widget on
        # a second `s._render`, which is unrelated to the teardown path here.)
        box.style.background_image = nil
        box._render
        box.background_media.should be_nil
      end
    end
  end
end
