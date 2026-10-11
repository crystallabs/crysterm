require "./spec_helper"

include Crysterm

# A real PNG shipped in the repo, decoded by the pure-Crystal PNGGIF reader.
private def bg_image_path
  "#{__DIR__}/../data/image/matterhorn.png"
end

# A box with a background image on a headless window, painted once so its
# layer exists; the block gets both. The two media options are put back to
# their defaults afterwards, whatever the block set them to.
private def with_background_box(&)
  s = headless_screen(80, 24, default_quit_keys: true)
  begin
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 12, height: 6, content: "Hi"
    box.style.background_image = bg_image_path
    s.repaint
    yield s, box
  ensure
    Crysterm::Config.reset "media.backend"
    Crysterm::Config.reset "media.exclude"
    s.destroy
  end
end

describe "Widget::Media backend change at run time" do
  it "rebuilds a background-image layer for a backend pinned while it is on screen" do
    with_background_box do |s, box|
      first = box.background_media.should_not be_nil
      first.is_a?(Widget::Media::Cells).should be_true # auto: no Kitty on a headless terminal

      Crysterm::Config.media_backend = Widget::Media::Backend::AnsiC16
      s.repaint
      second = box.background_media.should_not be_nil
      second.should be_a(Widget::Media::Ascii::C16)
      second.should_not be(first)
      box.children.should_not contain(first) # the old layer is destroyed, not left behind

      Crysterm::Config.media_backend = Widget::Media::Backend::GlyphAscii
      s.repaint
      box.background_media.should be_a(Widget::Media::Ascii::Edge)
      # The new layer paints: an empty cell carries an image color.
      Crysterm::Attr.bg(s.cell_rows[3][5].attr).should_not eq Crysterm::Attr::COLOR_DEFAULT
      s.cell_rows[0][0].char.should eq 'H' # the text stays on top
    end
  end

  it "honors the pin even where the terminal cannot drive it, as resolve does" do
    with_background_box do |s, box|
      Crysterm::Config.media_backend = Widget::Media::Backend::Kitty
      s.repaint
      box.background_media.should be_a(Widget::Media::Kitty)
      box.background_paints_cells?.should be_false
    end
  end

  it "goes back to the auto-detected backend when the option is reset" do
    with_background_box do |s, box|
      Crysterm::Config.media_backend = Widget::Media::Backend::Kitty
      s.repaint
      box.background_media.should be_a(Widget::Media::Kitty)

      Crysterm::Config.reset "media.backend"
      s.repaint
      box.background_media.should_not be_nil
      box.background_media.is_a?(Widget::Media::Cells).should be_true
    end
  end

  it "rebuilds the layer when the exclude list changes" do
    with_background_box do |s, box|
      Crysterm::Config.media_exclude = "kitty,glyph"
      s.repaint
      box.background_media.should be_a(Widget::Media::Ansi)

      Crysterm::Config.media_exclude = "kitty,ansi"
      s.repaint
      box.background_media.should be_a(Widget::Media::Glyph)
    end
  end

  it "leaves a widget without a background image alone" do
    s = headless_screen(80, 24, default_quit_keys: true)
    begin
      box = Widget::Box.new parent: s, top: 0, left: 0, width: 8, height: 3, content: "hi"
      s.repaint
      Widget::Media.watch_config
      Crysterm::Config.media_backend = Widget::Media::Backend::AnsiC8
      s.repaint
      box.background_media.should be_nil
      s.cell_rows[0][0].char.should eq 'h'
    ensure
      Crysterm::Config.reset "media.backend"
      s.destroy
    end
  end

  it "reaches every live window" do
    with_background_box do |s, box|
      other = headless_screen(40, 10, default_quit_keys: true)
      begin
        other_box = Widget::Box.new parent: other, top: 0, left: 0, width: 10, height: 4
        other_box.style.background_image = bg_image_path
        other.repaint
        other_box.background_media.is_a?(Widget::Media::Cells).should be_true

        Crysterm::Config.media_backend = Widget::Media::Backend::AnsiC256
        s.repaint
        other.repaint
        box.background_media.should be_a(Widget::Media::Ascii::C256)
        other_box.background_media.should be_a(Widget::Media::Ascii::C256)
      ensure
        other.destroy
      end
    end
  end
end

describe "Widget::Media::Backend" do
  it "maps each member but Auto to its Type" do
    Widget::Media::Backend::Auto.type.should be_nil
    Widget::Media::Backend.values.each do |backend|
      next if backend.auto?
      backend.type.should eq Widget::Media::Type.parse(backend.to_s)
    end
  end

  it "names each member for a menu" do
    Widget::Media::Backend::Auto.label.should eq "Auto-detect"
    Widget::Media::Backend::Kitty.label.should eq "Kitty graphics"
    Widget::Media::Backend::GlyphHalf.label.should eq "Unicode half blocks"
    Widget::Media::Backend.values.map(&.label).uniq.size.should eq Widget::Media::Backend.values.size
  end

  it "groups the members by how the pixels reach the window" do
    Widget::Media::Backend::Auto.family.should be_nil
    Widget::Media::Backend::Ansi.family.should eq Widget::Media::Family::Cells
    Widget::Media::Backend::GlyphBraille.family.should eq Widget::Media::Family::Cells
    Widget::Media::Backend::Sixel.family.should eq Widget::Media::Family::Graphics
    Widget::Media::Backend::Kitty.family.should eq Widget::Media::Family::Graphics
    Widget::Media::Backend::Overlay.family.should eq Widget::Media::Family::External
    Widget::Media::Backend::Ueberzug.family.should eq Widget::Media::Family::External
    Widget::Media::Backend::Tek.family.should eq Widget::Media::Family::Window
  end

  it "says whether a member can be driven here, Auto always" do
    s = headless_screen(80, 24, default_quit_keys: true)
    begin
      Widget::Media::Backend::Auto.available?(s.tput).should be_true
      Widget::Media::Backend::Ansi.available?(s.tput).should be_true
      Widget::Media::Backend::GlyphAscii.available?(s.tput).should be_true
      Widget::Media::Backend::Regis.available?(s.tput).should be_false # no detection
      Widget::Media::Backend::Tek.available?(s.tput).should be_false
      Widget::Media::Backend.values.each do |backend|
        next if backend.auto?
        backend.available?(s.tput).should eq Widget::Media.available?(backend.type.not_nil!, s.tput)
      end
    ensure
      s.destroy
    end
  end
end
