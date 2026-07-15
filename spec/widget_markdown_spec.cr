require "./spec_helper"

include Crysterm

private def md_screen(w = 50, h = 16)
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new, width: w, height: h)
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

private def md_render(doc, w = 46, h = 18)
  s = Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new, width: w, height: h)
  saved = Crysterm::CSS.default_stylesheet
  Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
  Crysterm::Widget::Markdown.new parent: s, top: 0, left: 0, width: w, height: h, markdown: doc
  s._render
  text = (0...s.aheight).map { |y| (0...s.awidth).map { |x| c = s.lines[y][x].char; c == '\0' ? ' ' : c }.join }.join("\n")
  Crysterm::CSS.default_stylesheet = saved
  text
end

private def struck?(s, ch : Char) : Bool
  found = false
  (0...s.aheight).each do |y|
    (0...s.awidth).each do |x|
      c = s.lines[y][x]
      found = (Crysterm::Attr.flags(c.attr) & Crysterm::Attr::STRIKE) != 0 if c.char == ch
    end
  end
  found
end

private def md_attr_screen(doc, w = 40, h = 6)
  s = md_screen w, h
  saved = Crysterm::CSS.default_stylesheet
  Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
  Crysterm::Widget::Markdown.new parent: s, top: 0, left: 0, width: w, height: h, markdown: doc
  s._render
  Crysterm::CSS.default_stylesheet = saved
  s
end

describe "Markdown GFM extensions" do
  it "renders strikethrough with the STRIKE attribute" do
    s = md_screen 30, 4
    saved = Crysterm::CSS.default_stylesheet
    Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
    begin
      Crysterm::Widget::Markdown.new parent: s, top: 0, left: 0, width: 30, height: 4,
        markdown: "Some ~~struck~~ text.\n"
      s._render
      txt = text_of s
      txt.includes?("~~").should be_false # markers consumed
      txt.includes?("struck").should be_true
      # The struck letters carry Attr::STRIKE; the surrounding words do not.
      struck = nil
      plain = nil
      (0...s.aheight).each do |y|
        (0...s.awidth).each do |x|
          c = s.lines[y][x]
          struck = (Crysterm::Attr.flags(c.attr) & Crysterm::Attr::STRIKE) != 0 if c.char == 'r'
          plain = (Crysterm::Attr.flags(c.attr) & Crysterm::Attr::STRIKE) != 0 if c.char == 'S'
        end
      end
      struck.should be_true # 'r' of "struck"
      plain.should be_false # 'S' of "Some"
    ensure
      Crysterm::CSS.default_stylesheet = saved
    end
  end

  it "renders task lists as checkboxes" do
    t = md_render "- [ ] todo\n- [x] done\n- normal\n"
    t.includes?("☐ todo").should be_true
    t.includes?("☑ done").should be_true
    t.includes?("• normal").should be_true
    t.includes?("[ ]").should be_false
    t.includes?("[x]").should be_false
  end

  it "renders GFM tables as box-drawing tables with alignment" do
    t = md_render "| Name | Score |\n|:-----|------:|\n| Alice | 42 |\n| Bob | 7 |\n"
    t.includes?("┌").should be_true
    t.includes?("├").should be_true
    t.includes?("└").should be_true
    t.includes?("Name").should be_true
    t.includes?("Alice").should be_true
    # Right-aligned Score column: the number hugs the right cell edge.
    t.includes?("42 │").should be_true
    t.includes?("| Name").should be_false # raw pipes consumed
  end

  it "ignores a hard line break inside a table (no stray blank line)" do
    # markd parses a table row ending in trailing spaces as a hard LineBreak
    # node; like a soft break it must be swallowed so output matches the clean one.
    clean = md_render "| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n"
    hard = md_render "| A | B |\n|---|---|\n| 1 | 2 |  \n| 3 | 4 |\n"
    hard.should eq clean
  end

  it "leaves tildes inside inline code alone" do
    s = md_attr_screen "`~~not struck~~`\n"
    text_of(s).includes?("~~not struck~~").should be_true
    struck?(s, 'k').should be_false
  end

  it "strikes across inline markup" do
    s = md_attr_screen "~~a **b** c~~\n"
    text_of(s).includes?("~~").should be_false
    # The bold run sits in the middle of the strikethrough, and is struck too.
    struck?(s, 'b').should be_true
  end

  it "keeps a pipe inside a cell's inline code out of the column split" do
    t = md_render "| `x\\|y` | z |\n|---|---|\n| a | b |\n"
    t.includes?("│ x|y │ z │").should be_true
  end

  it "styles markup inside cells without disturbing the borders" do
    t = md_render "| A | B |\n|---|---|\n| **bold** | [lnk](http://e.co) |\n"
    t.includes?("┌──────┬─────┐").should be_true
    t.includes?("│ bold │ lnk │").should be_true
  end

  it "measures a cell containing braces by its visible width" do
    # `{`/`}` are escaped to `{open}`/`{close}` — tag-shaped, but one column
    # each. Measuring the escaped text would over-count and skew the border.
    t = md_render "| A | B |\n|---|---|\n| a{b}c | x |\n"
    t.includes?("┌───────┬───┐").should be_true
    t.includes?("│ a{b}c │ x │").should be_true
  end

  it "pads ragged rows and truncates overlong ones to the header" do
    t = md_render "| A | B |\n|---|---|\n| ragged |\n| 1 | 2 | 3 |\n"
    t.includes?("│ ragged │   │").should be_true
    t.includes?("│ 1      │ 2 │").should be_true
  end

  it "renders a broken table as literal text, not a box" do
    t = md_render "| A | B |\n| broken |\n"
    t.includes?("| A | B |").should be_true
    t.includes?("┌").should be_false
  end

  it "omits the body separator from a header-only table" do
    t = md_render "| Only | Header |\n|---|---|\n"
    t.includes?("│ Only │ Header │").should be_true
    t.includes?("├").should be_false
  end

  it "renders an alert as a titled quote" do
    t = md_render "> [!NOTE] Heads up\n> body text\n"
    t.includes?("│ Heads up").should be_true
    t.includes?("│ body text").should be_true
    t.includes?("[!NOTE]").should be_false
  end

  it "titles a bare alert with its kind" do
    t = md_render "> [!WARNING]\n> careful\n"
    t.includes?("│ WARNING").should be_true
    t.includes?("│ careful").should be_true
  end

  it "does not gap a task list from the plain bullets following it" do
    # markd splits checkbox and bullet items into separate Lists; they should
    # still read as one list.
    t = md_render "- [ ] todo\n- [x] done\n- normal\n"
    lines = t.lines.map(&.strip).reject(&.empty?)
    lines[0..2].should eq ["☐ todo", "☑ done", "• normal"]
  end
end
