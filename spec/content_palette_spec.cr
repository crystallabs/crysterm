require "./spec_helper"

include Crysterm

# A rich-text document carries only semantics (heading level, `code`,
# `code_language`, anchors, `rule`, `dim`); the *view* colors them from its
# style's content slots (`TextEdit::heading { color: … }` and friends),
# resolved into a `ContentPalette` each frame. The default theme fills the
# slots; a stylesheet overrides them; the QSS translator lets Qt text-widget
# rules reach the rich widgets.

private def cp_fg(s, x, y) : Int32
  Attr.unpack_color(Attr.fg(s.cell_rows[y][x].attr))
end

private def cp_bg(s, x, y) : Int32
  Attr.unpack_color(Attr.bg(s.cell_rows[y][x].attr))
end

describe "CSS::Qss: rich text widgets" do
  it "maps QTextEdit/QTextBrowser onto TextEdit/TextBrowser and leaves QPlainTextEdit alone" do
    css = Crysterm::CSS::Qss.to_css("QTextEdit { color: red; }\nQTextBrowser:focus { color: blue; }\nQPlainTextEdit { color: green; }")
    css.should contain "TextEdit { color: red; }"
    css.should contain "TextBrowser:focus { color: blue; }"
    css.should contain "PlainTextEdit { color: green; }"
    css.should_not contain "ScrollableText"
  end
end

describe "importers store semantics, not colors" do
  it "markdown: headings, code, links, images, fences and tables" do
    doc = TextDocument.from_markdown "# T\n\n`c` [l](x) ![alt](i.png)\n\n```crystal\nb\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n"
    formats = [] of TextCharFormat
    doc.blocks.each { |b| b.fragments.each { |f| formats << f.format } }
    formats.each do |f|
      f.fg.should be_nil
      f.bg.should be_nil
    end
    doc.blocks[0].block_format.heading_level.should eq 1
    formats.find!(&.code?).should_not be_nil
    formats.find!(&.anchor?).anchor_href.should eq "x"
    formats.any?(&.dim?).should be_true
    fence = doc.blocks.find! { |b| b.text == "b" }.block_format
    fence.code_block?.should be_true
    fence.code_language.should eq "crystal"
    fence.bg.should be_nil
    border = doc.blocks.find!(&.text.starts_with?("┌"))
    border.fragments[0].format.rule?.should be_true
    # Borders stay distinct fragments from the cell text they sit beside.
    row = doc.blocks.find! { |b| b.text.includes?("1") && b.text.includes?("│") }
    row.fragments.size.should be > 1
    row.fragments[0].format.rule?.should be_true
  end

  it "html: headings, code, links and pre" do
    doc = TextDocument.from_html %(<h1>T</h1><p><code>c</code> <a href="x">l</a></p><pre>b</pre>)
    doc.blocks.each { |b| b.fragments.each { |f| f.format.fg.should be_nil; f.format.bg.should be_nil } }
    doc.blocks.find! { |b| b.text == "b" }.block_format.code_block?.should be_true
  end

  it "inline TOC entries carry anchors only" do
    doc = TextDocument.from_markdown "# A\n\n## B\n"
    doc.cursor(0).insert_toc
    links = [] of TextCharFormat
    doc.blocks.each { |b| b.fragments.each { |f| links << f.format if f.format.anchor? } }
    links.size.should eq 2
    links.each(&.fg.should(be_nil))
  end
end

describe "exporters fence code blocks by the semantic marker" do
  it "markdown re-emits the fence with its info string" do
    doc = TextDocument.from_markdown "```crystal\nputs 1\n\nputs 2\n```\n"
    md = doc.to_markdown
    md.should start_with "```crystal\n"
    back = TextDocument.from_markdown(md)
    back.blocks.map(&.block_format.code_language).should eq ["crystal", "crystal", "crystal"]
    back.to_markdown.should eq md
  end

  it "html exports a code block as <pre> (with its language) and re-imports it as one" do
    doc = TextDocument.from_markdown "```\nx\n```\n"
    html = doc.to_html
    html.should contain "<pre>"
    html.should_not contain "background-color"
    TextDocument.from_html(html).blocks[0].block_format.code_block?.should be_true

    lang = TextDocument.from_markdown "```crystal\nx\n```\n"
    lang.to_html.should contain %(<pre class="language-crystal">)
    TextDocument.from_html(lang.to_html).to_markdown.should eq lang.to_markdown
    TextDocument.from_html(%(<pre><code class="language-ruby">y</code></pre>)).blocks[0].block_format.code_language.should eq "ruby"

    # A fence inside a list item, and one as list continuation content, keep
    # their place through HTML.
    ["- ```\n  code\n  ```\n", "- item\n\n  ```\n  code\n  ```\n"].each do |md|
      d = TextDocument.from_markdown(md)
      TextDocument.from_html(d.to_html).to_markdown.should eq d.to_markdown
    end
  end

  it "tags round-trip the code block, its language and the rule flag" do
    doc = TextDocument.from_markdown "```crystal\nx\n```\n"
    tags = doc.tags
    tags.should contain "code-crystal"
    tags.should_not contain "-fg}"
    back = TextDocument.new
    back.tags = tags
    back.blocks[0].block_format.code_language.should eq "crystal"
    back.to_markdown.should eq doc.to_markdown

    table = TextDocument.from_markdown "| a |\n|---|\n| 1 |\n"
    ttags = table.tags
    ttags.should contain "{rule}"
    rebuilt = TextDocument.new
    rebuilt.tags = ttags
    rebuilt.blocks[0].fragments[0].format.rule?.should be_true
  end

  it "tags colored by a palette carry the colors a view would paint" do
    doc = TextDocument.from_markdown "# T\n\n`c` [l](x)\n"
    pal = ContentPalette.new(heading: 0x111111, code: 0x222222, code_bg: 0x333333, link: 0x444444)
    tags = doc.to_tags(pal)
    tags.should contain "{#111111-fg}T"
    tags.should contain "{#222222-fg}{#333333-bg}{code}c"
    tags.should contain "{#444444-fg}l"
    doc.to_tags.should_not contain "-fg}"
  end
end

describe "ContentPalette" do
  it "derives the code background from the surface" do
    ContentPalette.code_bg_for(0x1d2023).should eq Colors.lighten(0x1d2023, ContentPalette::CODE_BG_LIFT_DARK)
    ContentPalette.code_bg_for(0xeff0f1).should eq Colors.darken(0xeff0f1, ContentPalette::CODE_BG_LIFT_LIGHT)
  end

  it "reads only slot colors that differ from the widget's own" do
    st = Style.new(fg: 0x31363b, bg: 0xeff0f1)
    ContentPalette.from_style(st).heading.should be_nil
    slot = st.dup
    slot.fg = 0x123456
    st.heading = slot
    inherited = st.dup
    st.code = inherited
    pal = ContentPalette.from_style(st)
    pal.heading.should eq 0x123456
    pal.code.should be_nil
    pal.code_bg.should eq ContentPalette.code_bg_for(0xeff0f1)
  end
end

describe "Widget::TextEdit paints the document from its content slots" do
  it "colors headings, code and links per the stylesheet, and recolors on a restyle" do
    s = headless_screen(60, 24)
    s.stylesheet = <<-CSS
      TextBrowser { background-color: #eff0f1; color: #31363b; }
      TextBrowser::heading { color: #1f5fbf; }
      TextBrowser::code { color: #a3400a; }
      TextBrowser::link { color: #0b6fa4; }
      CSS
    tb = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: 40, height: 8
    tb.markdown = "# Title\n\n`c` [l](x)\n\n```\nb\n```\n"
    s.repaint
    tb.palette.heading.should eq 0x1f5fbf
    tb.palette.code_bg.should eq ContentPalette.code_bg_for(0xeff0f1)
    cp_fg(s, 0, 0).should eq 0x1f5fbf
    cp_bg(s, 0, 0).should eq 0xeff0f1
    cp_fg(s, 0, 2).should eq 0xa3400a
    cp_bg(s, 0, 2).should eq ContentPalette.code_bg_for(0xeff0f1)
    cp_fg(s, 2, 2).should eq 0x0b6fa4
    cp_bg(s, 0, 4).should eq ContentPalette.code_bg_for(0xeff0f1) # fenced line
    # The document itself stayed uncolored.
    tb.document.blocks[0].fragments[0].format.fg.should be_nil

    s.stylesheet = <<-CSS
      TextBrowser { background-color: #1d2023; color: #eff0f1; }
      TextBrowser::heading { color: #86b5ff; }
      CSS
    s.repaint
    tb.palette.heading.should eq 0x86b5ff
    cp_fg(s, 0, 0).should eq 0x86b5ff
    cp_bg(s, 0, 2).should eq ContentPalette.code_bg_for(0x1d2023)
    # No author `code` rule now: the default theme's `TextEdit::code` color
    # shows through instead of the override.
    cp_fg(s, 0, 2).should_not eq 0xa3400a
    cp_fg(s, 0, 2).should eq tb.palette.code.not_nil!
  end

  it "paints one shared document in each view's colors" do
    s = headless_screen(80, 24)
    s.stylesheet = <<-CSS
      #a::heading { color: #111111; }
      #b::heading { color: #222222; }
      CSS
    doc = TextDocument.from_markdown "# T"
    a = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: 20, height: 4, document: doc
    a.css_id = "a"
    b = Widget::TextBrowser.new parent: s, left: 20, top: 0, width: 20, height: 4, document: doc
    b.css_id = "b"
    s.repaint
    a.palette.heading.should eq 0x111111
    b.palette.heading.should eq 0x222222
    cp_fg(s, 0, 0).should eq 0x111111
    cp_fg(s, 20, 0).should eq 0x222222
  end

  it "paints a code span in a heading in the heading color, and links over everything" do
    s = headless_screen(60, 24)
    s.stylesheet = <<-CSS
      TextBrowser { background-color: #1d2023; color: #eff0f1; }
      TextBrowser::heading { color: #111111; }
      TextBrowser::code { color: #222222; }
      TextBrowser::link { color: #333333; }
      CSS
    tb = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: 40, height: 8
    tb.markdown = "# A `c` [l](x)"
    s.repaint
    cp_fg(s, 0, 0).should eq 0x111111
    cp_fg(s, 2, 0).should eq 0x111111                             # code in a heading keeps the heading color…
    cp_bg(s, 2, 0).should eq ContentPalette.code_bg_for(0x1d2023) # …over its code background
    cp_fg(s, 4, 0).should eq 0x333333                             # a link wins
  end

  it "turns the code background off with `transparent`, or sets it explicitly" do
    s = headless_screen(60, 24)
    s.stylesheet = <<-CSS
      TextBrowser { background-color: #1d2023; color: #eff0f1; }
      TextBrowser::code { background-color: transparent; }
      CSS
    tb = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: 40, height: 8
    tb.markdown = "`c`\n\n```\nb\n```\n"
    s.repaint
    tb.palette.code_bg.should be_nil
    cp_bg(s, 0, 0).should eq 0x1d2023
    cp_bg(s, 0, 2).should eq 0x1d2023

    s.stylesheet = <<-CSS
      TextBrowser { background-color: #1d2023; color: #eff0f1; }
      TextBrowser::code { background-color: #445566; }
      CSS
    s.repaint
    tb.palette.code_bg.should eq 0x445566
    cp_bg(s, 0, 0).should eq 0x445566
    cp_bg(s, 0, 2).should eq 0x445566
  end

  it "colors GFM alerts from their own slots, falling back to the quote color" do
    s = headless_screen(60, 24)
    s.stylesheet = <<-CSS
      TextBrowser { background-color: #1d2023; color: #eff0f1; }
      TextBrowser::quote { color: #777777; }
      TextBrowser::tip { color: #00ff00; }
      TextBrowser::caution { color: #ff0000; }
      CSS
    tb = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: 40, height: 12
    tb.markdown = "> [!TIP]\n> t\n\n> [!CAUTION]\n> c\n\n> q\n"
    s.repaint
    tb.palette.tip.should eq 0x00ff00
    tb.palette.alert(TextBlockFormat::AlertKind::Caution).should eq 0xff0000
    rows = (0...12).map { |y| (0...20).map { |x| s.cell_rows[y][x].char }.join }
    tip_row = rows.index!(&.includes?("TIP"))
    caution_row = rows.index!(&.includes?("CAUTION"))
    quote_row = rows.index!(&.starts_with?("│ q"))
    cp_fg(s, 0, tip_row).should eq 0x00ff00
    cp_fg(s, 0, caution_row).should eq 0xff0000
    cp_fg(s, 0, quote_row).should eq 0x777777
    # The default theme fills the alert slots too.
    s2 = headless_screen(60, 24)
    tb2 = Widget::TextBrowser.new parent: s2, left: 0, top: 0, width: 40, height: 8
    tb2.markdown = "> [!NOTE]\n> n\n"
    s2.repaint
    TextBlockFormat::AlertKind.each { |k| tb2.palette.alert(k).should_not be_nil }
  end

  it "shades an unknown background from the active theme's surface" do
    saved = Crysterm::CSS.theme
    begin
      Crysterm::CSS.theme = Crysterm::CSS::Theme.light
      light = ContentPalette.code_bg_for(nil)
      light.should eq Colors.darken(Crysterm::CSS::Theme.light.primaries["surface"], ContentPalette::CODE_BG_LIFT_LIGHT)
      Crysterm::CSS.theme = Crysterm::CSS::Theme.dark
      ContentPalette.code_bg_for(nil).should eq Colors.lighten(Crysterm::CSS::Theme.dark.primaries["surface"], ContentPalette::CODE_BG_LIFT_DARK)
    ensure
      Crysterm::CSS.theme = saved
    end
  end

  it "memoizes the palette until its inputs change" do
    memo = ContentPalette::Memo.new
    st = Style.new(fg: 0x31363b, bg: 0xeff0f1)
    first = memo.fetch(st, 0xeff0f1)
    memo.fetch(st, 0xeff0f1).should eq first
    slot = st.dup
    slot.fg = 0x123456
    st.heading = slot
    memo.fetch(st, 0xeff0f1).heading.should eq 0x123456
    slot.fg = 0x654321 # in-place edit of an assigned slot
    memo.fetch(st, 0xeff0f1).heading.should eq 0x654321
    memo.fetch(st, 0x1d2023).code_bg.should eq ContentPalette.code_bg_for(0x1d2023)
  end

  it "gets its slots filled by the default theme" do
    s = headless_screen(60, 24)
    tb = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: 40, height: 8
    tb.markdown = "# T"
    s.repaint
    tb.palette.heading.should_not be_nil
    tb.palette.link.should_not be_nil
    tb.palette.code.should_not be_nil
  end
end
