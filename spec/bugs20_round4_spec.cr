require "./spec_helper"

private R4_URL = "http://media.invalid/pic.png"

private def r4_png : Bytes
  PNGGIF.encode_png(Array.new(16) { Array.new(16) { PNGGIF::Pixel.new(200, 100, 50) } })
end

# Runs the block with a fetcher that records each URL asked for, putting it,
# the `media.remote_fetch` option and the decode cache back after.
private def r4_recording_fetches(allow : Bool, &)
  previous = Crysterm::Widget::Media.fetcher
  allowed = Crysterm::Config.media_remote_fetch
  fetched = [] of String
  begin
    Crysterm::Widget::Media.fetcher = ->(u : String) : Bytes { fetched << u; r4_png }
    Crysterm::Config.media_remote_fetch = allow
    yield fetched
  ensure
    Crysterm::Widget::Media.fetcher = previous
    Crysterm::Config.media_remote_fetch = allowed
    Crysterm::Widget::Media.clear_decode_cache
  end
end

describe "Unicode.picture_controls" do
  it "puts a one-column picture in place of each control character" do
    Crysterm::Unicode.picture_controls("a\u0007b\e[1m\u007f\u009b").should eq "a␇b␛[1m␡�"
    Crysterm::Unicode.str_width("␇␛␡�", true).should eq 4
  end

  it "leaves TAB and the line separators, and returns clean text itself" do
    text = "a\tb\nc\rd é"
    Crysterm::Unicode.picture_controls(text).should be text
  end
end

{true, false}.each do |full|
  describe "control characters in an editor's value (full_unicode: #{full})" do
    it "shows one cell each in a PlainTextEdit, with the caret and clicks in step" do
      s = headless_screen(30, 6)
      s.full_unicode = full
      {true, false}.each do |wrap|
        te = Crysterm::Widget::PlainTextEdit.new parent: s, top: 0, left: 0, width: 20, height: 3,
          wrap_content: wrap
        te.value = "a\u0007b\e[31mc"
        te.focus
        s.repaint
        row_text(s, 0).should eq "a␇b␛[31mc"
        te.value.should eq "a\u0007b\e[31mc"
        te.position_at(3, 0).should eq 3
        te.position_at(8, 0).should eq 8
        te.cursor_position = 3
        s.repaint
        s.tput.cursor.x.should eq 3
        te.destroy
      end
    ensure
      s.try &.destroy
    end

    it "patches a typed line with its pictures" do
      s = headless_screen(30, 6)
      s.full_unicode = full
      te = Crysterm::Widget::PlainTextEdit.new parent: s, top: 0, left: 0, width: 20, height: 3
      te.value = "x\u0001y\nsecond"
      te.focus
      s.repaint
      te.cursor_position = 3
      te.insert_text "z"
      s.repaint
      row_text(s, 0).should eq "x␁yz"
      row_text(s, 1).should eq "second"
    ensure
      s.try &.destroy
    end

    it "shows one cell each in a LineEdit" do
      s = headless_screen(30, 6)
      s.full_unicode = full
      le = Crysterm::Widget::LineEdit.new parent: s, top: 0, left: 0, width: 20, height: 1
      le.value = "a\u0007b\e[31mc"
      s.repaint
      row_text(s, 0).should eq "a␇b␛[31mc"
      le.value.should eq "a\u0007b\e[31mc"
    ensure
      s.try &.destroy
    end

    it "shows one cell each in a rich TextEdit block" do
      s = headless_screen(30, 6)
      s.full_unicode = full
      te = Crysterm::Widget::TextEdit.new parent: s, top: 0, left: 0, width: 20, height: 3
      te.set_text "a\u0007b\u009bc"
      s.repaint
      row_text(s, 0).should eq "a␇b�c"
      te.document.to_plain_text.should eq "a\u0007b\u009bc"
    ensure
      s.try &.destroy
    end
  end
end

describe "media.remote_fetch and images named by content" do
  it "never fetches a document's remote image while the option is off" do
    r4_recording_fetches(false) do |fetched|
      s = headless_screen(40, 10)
      begin
        te = Crysterm::Widget::TextEdit.new parent: s, top: 0, left: 0, width: 40, height: 10
        te.set_markdown "before\n\n![pic](#{R4_URL})\n\nafter"
        s.repaint
        Fiber.yield
        s.repaint
        fetched.should be_empty
        te.children.any?(Crysterm::Widget::Media::Base).should be_false
      ensure
        s.destroy
      end
    end
  end

  it "fetches it once the option allows" do
    r4_recording_fetches(true) do |fetched|
      s = headless_screen(40, 10)
      begin
        te = Crysterm::Widget::TextEdit.new parent: s, top: 0, left: 0, width: 40, height: 10
        te.set_markdown "before\n\n![pic](#{R4_URL})\n\nafter"
        s.repaint
        wait_until { !fetched.empty? }
        fetched.should eq [R4_URL]
      ensure
        s.destroy
      end
    end
  end

  it "builds no layer for a remote background-image while the option is off, and one after it is set" do
    r4_recording_fetches(false) do |fetched|
      s = headless_screen(20, 6)
      begin
        box = Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 4
        box.style.background_image = R4_URL
        s.repaint
        Fiber.yield
        fetched.should be_empty
        box.background_media.nil?.should be_true

        Crysterm::Config.media_remote_fetch = true
        s.repaint
        box.background_media.nil?.should be_false
        wait_until { !fetched.empty? }
      ensure
        s.destroy
      end
    end
  end

  it "still paints a local background-image while the option is off" do
    r4_recording_fetches(false) do |_fetched|
      path = File.tempname("r4bg", ".png")
      File.write path, r4_png
      s = headless_screen(20, 6)
      begin
        box = Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 4
        box.style.background_image = path
        s.repaint
        box.background_media.nil?.should be_false
      ensure
        s.destroy
        File.delete? path
      end
    end
  end
end
