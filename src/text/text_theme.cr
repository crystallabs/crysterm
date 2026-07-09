module Crysterm
  # Colors the interchange importers (`TextMarkdown`, `TextHtml`) give
  # semantic elements that have no terminal-native appearance of their own —
  # a heading or code span has to become *some* color on a cell grid. The
  # defaults match `Widget::Markdown`'s, so imported documents look like the
  # existing markdown viewer. Exporters never read the theme: they key on the
  # semantic properties (`heading_level`, `TextCharFormat#code?`,
  # `anchor_href`), so a retheme doesn't break round-trips.
  record TextTheme,
    heading_color : Int32 = 0x86B5FF,
    code_color : Int32 = 0xE0A85C,
    code_bg : Int32 = 0x202833,
    quote_color : Int32 = 0x86C58A,
    link_color : Int32 = 0x4FB6E6,
    rule_color : Int32 = 0x404A57,
    muted_color : Int32 = 0x808A96 do
    # Shared all-defaults instance.
    class_getter default : TextTheme = new
  end
end
