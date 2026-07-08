require "./spec_helper"

include Crysterm

private def headless_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: 24)
end

# A real PNG shipped in the repo, decoded by the pure-Crystal PNGGIF reader.
private def bg_image_path
  "#{__DIR__}/../data/image/matterhorn.png"
end

# Runs *block* with `image.exclude` set to *value*, restoring it afterward, so
# a test can force a particular backend without leaking global config.
private def with_media_exclude(value : String, &)
  orig = Crysterm::Config.media_exclude
  Crysterm::Config.media_exclude = value
  begin
    yield
  ensure
    Crysterm::Config.media_exclude = orig
  end
end

describe "multi-line content over a cells background" do
  it "renders each line on its own row (newline terminates the row)" do
    with_media_exclude("kitty") do
      s = headless_screen
      box = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 5, content: "ab\ncd"
      box.style.background_image = bg_image_path
      s._render

      box.background_paints_cells?.should be_true

      s.lines[0][0].char.should eq 'a'
      s.lines[0][1].char.should eq 'b'
      s.lines[1][0].char.should eq 'c'
      s.lines[1][1].char.should eq 'd'

      # The second line's text must not leak onto row 0 (the defect painted
      # "cd" right after "ab" on the first row).
      (2...10).each do |x|
        s.lines[0][x].char.should_not eq 'c'
        s.lines[0][x].char.should_not eq 'd'
      end
    end
  end

  it "keeps the image showing in the row remainder after a newline" do
    with_media_exclude("kitty") do
      s = headless_screen
      box = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 5, content: "ab\ncd"
      box.style.background_image = bg_image_path
      s._render

      # Cells after "ab" on row 0 keep the painted image rather than being
      # cleared to the widget fill.
      Crysterm::Attr.bg(s.lines[0][5].attr).should_not eq Crysterm::Attr::COLOR_DEFAULT
    end
  end

  it "leaves multi-line rendering without a cells background unchanged" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 5, content: "ab\ncd"
    s._render

    box.background_paints_cells?.should be_false
    s.lines[0][0].char.should eq 'a'
    s.lines[0][1].char.should eq 'b'
    s.lines[1][0].char.should eq 'c'
    s.lines[1][1].char.should eq 'd'
  end
end
