# FEATURE: Syntax highlighting.
#
# `Crysterm::SyntaxHighlighter` is a Qt-style (`QSyntaxHighlighter`) per-block
# highlighting engine: subclass it, implement `#highlight_block`, and call
# `#set_format` for each span to color. Attached to a `TextDocument`, it
# re-runs incrementally as the document changes and its formats overlay the
# text without touching the content itself.
#
# Here a ~30-line regex-based Crystal highlighter colors a real Crysterm
# hello-world, shown in a read-only `Widget::TextEdit`.

require "../../src/crysterm"

include Crysterm

# A small Crystal-language highlighter: keywords, constants, symbols,
# numbers, strings and comments, colored for a dark background.
class CrystalHighlighter < SyntaxHighlighter
  KEYWORD = Crysterm::TextCharFormat.new(fg: 0xC678DD, bold: true)
  CONST   = Crysterm::TextCharFormat.new(fg: 0xE5C07B)
  SYMBOL  = Crysterm::TextCharFormat.new(fg: 0x56B6C2)
  NUMBER  = Crysterm::TextCharFormat.new(fg: 0xD19A66)
  STRING  = Crysterm::TextCharFormat.new(fg: 0x98C379)
  COMMENT = Crysterm::TextCharFormat.new(fg: 0x7F848E, italic: true)

  RULES = {
    /\b(?:require|class|def|end|do|include|new|true|false|nil|if|unless)\b/ => KEYWORD,
    /\b[A-Z][A-Za-z0-9_]*/                                                  => CONST,
    /:[a-z_][a-z0-9_]*/                                                     => SYMBOL,
    /\b(?:0x[0-9A-Fa-f]+|\d[\d_]*)\b/                                       => NUMBER,
    /"[^"]*"/                                                               => STRING,
    /#.*$/                                                                  => COMMENT,
  }

  def highlight_block(text : String)
    # Later rules overpaint earlier ones, so strings mask keywords inside
    # them and a trailing comment masks everything.
    RULES.each do |re, fmt|
      text.scan(re) { |md| set_format md.begin(0), md[0].size, fmt }
    end
  end
end

CODE = <<-'CRYSTAL'
  require "crysterm"

  # The smallest useful Crysterm application: a
  # titled window with one centered greeting box.
  class Hello
    include Crysterm
    def run
      w = Window.new title: "Hello"
      Widget::Box.new parent: w,
        top: "center", left: "center",
        width: 40, height: 5, parse_tags: true,
        content: "{center}Hello, Crysterm!{/center}",
        style: Style.new(border: true, bg: 0x103080)
      w.on(Event::KeyPress) { w.destroy }
      w.exec
    end
  end

  Hello.new.run
  CRYSTAL

s = Window.new title: "Syntax highlighting"

Widget::Box.new parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}SyntaxHighlighter — Qt-style per-block formats over a TextDocument{/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#202830")

edit = Widget::TextEdit.new parent: s, top: 2, left: "center", width: 64, height: 21,
  read_only: true, content: CODE, label: " hello.cr ",
  style: Style.new(border: true, fg: "#abb2bf", bg: "#0d1117")

CrystalHighlighter.new edit.document

s.exec
