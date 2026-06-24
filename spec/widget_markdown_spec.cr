require "./spec_helper"

include Crysterm

private def md_screen(w = 50, h = 16)
  Crysterm::Screen.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new, width: w, height: h)
end

private def text_of(s) : String
  (0...s.aheight).map { |y| (0...s.awidth).map { |x| c = s.lines[y][x].char; c == '\0' ? ' ' : c }.join }.join("\n")
end

describe Crysterm::Widget::Markdown do
  it "renders headings, emphasis, lists, code and quotes as styled text" do
    s = md_screen
    saved = Crysterm::CSS.default_stylesheet
    Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
    begin
      doc = "# Title\n\nSome **bold** and `code`.\n\n- one\n- two\n\n1. a\n2. b\n\n> quote\n\n```\nblk\n```\n"
      md = Crysterm::Widget::Markdown.new parent: s, top: 0, left: 0, width: 50, height: 16,
        markdown: doc, style: Crysterm::Style.new(border: true)
      s._render
      t = text_of s
      t.includes?("# Title").should be_true
      t.includes?("Some bold and code.").should be_true
      t.includes?("• one").should be_true
      t.includes?("1. a").should be_true
      t.includes?("│ quote").should be_true
      t.includes?("blk").should be_true
      md.markdown.should eq doc
    ensure
      Crysterm::CSS.default_stylesheet = saved
    end
  end

  it "collects links and activates them via Event::AnchorClick" do
    s = md_screen
    md = Crysterm::Widget::Markdown.new parent: s, width: 50, height: 10,
      markdown: "See [Crystal](https://crystal-lang.org) and [docs](https://docs.example)."
    md.links.size.should eq 2
    md.links[0].text.should eq "Crystal"
    md.links[0].url.should eq "https://crystal-lang.org"
    md.links[1].url.should eq "https://docs.example"

    got = nil
    md.on(Crysterm::Event::AnchorClick) { |e| got = e.url }
    md.activate_link "https://crystal-lang.org"
    got.should eq "https://crystal-lang.org"
  end

  it "applies styling attributes (bold heading color differs from body)" do
    s = md_screen
    saved = Crysterm::CSS.default_stylesheet
    Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
    begin
      Crysterm::Widget::Markdown.new parent: s, top: 0, left: 0, width: 50, height: 6,
        markdown: "# Hi\n\nbody\n", heading_color: 0x86B5FF
      s._render
      # Find the 'H' of the heading; its fg should be the heading color.
      heading_fg = nil
      (0...s.aheight).each do |y|
        (0...s.awidth).each do |x|
          heading_fg = Crysterm::Attr.fg(s.lines[y][x].attr) if s.lines[y][x].char == 'H'
        end
      end
      heading_fg.should eq 0x86B5FF
    ensure
      Crysterm::CSS.default_stylesheet = saved
    end
  end
end
