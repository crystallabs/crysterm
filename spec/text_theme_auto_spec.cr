require "./spec_helper"

include Crysterm

# A rich-text view follows the colors the CSS theme/stylesheet gives it: the
# QSS translator lets a Qt theme's `QTextEdit`/`QTextBrowser` rules reach the
# rich widgets, `TextTheme.for_colors` picks the palette for the resolved
# background, `TextDocument#theme=` recolors an already-imported document, and
# `Widget::TextEdit` derives its theme per frame unless one was assigned.

private def auto_theme_render(s)
  s.repaint
end

# Every fragment format of *doc*, in document order.
private def auto_theme_formats(doc) : Array(Crysterm::TextCharFormat)
  res = [] of Crysterm::TextCharFormat
  doc.blocks.each { |b| b.fragments.each { |f| res << f.format } }
  res
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

describe "TextTheme.for_colors" do
  it "picks the dark palette for a dark or unknown background and the light one for a light background" do
    TextTheme.for_colors(nil).should eq TextTheme.dark
    TextTheme.for_colors(-1).should eq TextTheme.dark
    TextTheme.for_colors(nil, dark: false).should eq TextTheme.light
    TextTheme.for_colors(0x1d2023).should eq TextTheme.dark.copy_with(code_bg: Colors.lighten(0x1d2023, TextTheme::CODE_BG_LIFT_DARK))
    TextTheme.for_colors(0xeff0f1).should eq TextTheme.light.copy_with(code_bg: Colors.darken(0xeff0f1, TextTheme::CODE_BG_LIFT_LIGHT))
  end

  it "keeps the all-defaults instance as the dark palette" do
    TextTheme.default.should eq TextTheme.dark
    TextTheme.new.should eq TextTheme.dark
  end
end

describe "TextDocument#theme=" do
  it "recolors what the old theme stamped and leaves other colors alone" do
    doc = TextDocument.from_markdown "# T\n\n`c` [l](x)\n\n```\nb\n```\n"
    doc.cursor(doc.size).insert_text "u", TextCharFormat.new(fg: 0x123456)
    heading = doc.blocks[0].fragments[0].format
    heading.fg.should eq TextTheme.dark.heading_color

    doc.theme = TextTheme.light
    doc.theme.should eq TextTheme.light
    doc.blocks[0].fragments[0].format.fg.should eq TextTheme.light.heading_color
    formats = auto_theme_formats(doc)
    code = formats.find! { |f| f.code? && f.bg }
    code.fg.should eq TextTheme.light.code_color
    code.bg.should eq TextTheme.light.code_bg
    link = formats.find!(&.anchor?)
    link.fg.should eq TextTheme.light.link_color
    # The appended "u" landed in the code block's last line, so that block
    # holds both a stamped color (recolored) and a user color (kept).
    code_block = doc.blocks.find! { |b| b.text == "bu" }
    code_block.block_format.bg.should eq TextTheme.light.code_bg
    code_block.fragments[0].format.fg.should eq TextTheme.light.code_color
    code_block.fragments[1].format.fg.should eq 0x123456
    doc.to_markdown.should eq TextDocument.from_markdown(doc.to_markdown).to_markdown
  end

  it "tells views to repaint through a zero-length Format change, and is a no-op for the same theme" do
    doc = TextDocument.from_markdown "# T"
    kinds = [] of TextDocument::ChangeKind
    doc.on(Event::ContentsChanged) { |e| kinds << e.kind }
    doc.theme = TextTheme.light
    kinds.should eq [TextDocument::ChangeKind::Format]
    doc.theme = TextTheme.light
    kinds.size.should eq 1
  end
end

describe "Widget::TextEdit auto theme" do
  it "derives the palette from the stylesheet's background and recolors the document" do
    s = headless_screen(60, 24)
    s.stylesheet = "TextBrowser { background-color: #eff0f1; color: #31363b; }"
    tb = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: 40, height: 8
    tb.markdown = "# Title\n\n`c`"
    tb.auto_theme?.should be_true
    # Imported before the first frame: stamped with the default (dark) theme.
    tb.document.blocks[0].fragments[0].format.fg.should eq TextTheme.dark.heading_color

    auto_theme_render s
    light = TextTheme.for_colors(0xeff0f1)
    tb.theme.should eq light
    tb.document.theme.should eq light
    tb.document.blocks[0].fragments[0].format.fg.should eq light.heading_color
    cell = s.cell_rows[0][0]
    cell.char.should eq 'T'
    Attr.unpack_color(Attr.fg(cell.attr)).should eq light.heading_color
    Attr.unpack_color(Attr.bg(cell.attr)).should eq 0xeff0f1

    # A restyle to a dark surface flips the palette back.
    s.stylesheet = "TextBrowser { background-color: #1d2023; color: #eff0f1; }"
    auto_theme_render s
    dark = TextTheme.for_colors(0x1d2023)
    tb.theme.should eq dark
    tb.document.blocks[0].fragments[0].format.fg.should eq dark.heading_color
    Attr.unpack_color(Attr.fg(s.cell_rows[0][0].attr)).should eq dark.heading_color
  end

  it "keeps an assigned theme instead of deriving one" do
    s = headless_screen(60, 24)
    s.stylesheet = "TextEdit { background-color: #eff0f1; color: #31363b; }"
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 8
    mine = TextTheme.new(heading_color: 0x123456)
    te.theme = mine
    te.auto_theme?.should be_false
    te.markdown = "# Title"
    auto_theme_render s
    te.theme.should eq mine
    te.document.blocks[0].fragments[0].format.fg.should eq 0x123456

    te.auto_theme = true
    auto_theme_render s
    te.theme.should eq TextTheme.for_colors(0xeff0f1)
    te.document.blocks[0].fragments[0].format.fg.should eq TextTheme.light.heading_color
  end

  it "recolors a document adopted from another theme" do
    s = headless_screen(60, 24)
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 8
    te.theme = TextTheme.light
    doc = TextDocument.from_markdown "# Title"
    te.document = doc
    doc.theme.should eq TextTheme.light
    doc.blocks[0].fragments[0].format.fg.should eq TextTheme.light.heading_color
  end
end
