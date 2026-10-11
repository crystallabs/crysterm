require "./spec_helper"

include Crysterm

# Installs *theme* for the block (see `bar_surface_inherit_spec.cr`).
private def with_theme(theme : Crysterm::CSS::Theme?, &)
  saved = Crysterm::CSS.theme
  Crysterm::CSS.theme = theme
  yield
ensure
  Crysterm::CSS.theme = saved
end

# A text browser filling the window with more lines than fit, so its vertical
# bar shows in the last column — under the theme a translucent `.scrollbar`
# layer (`z-index: 5; opacity: 0.82`). Painted once: the first frame creates
# the bar, and the next frame's cascade styles it, so the caller's own
# `repaint` sees the themed bar.
private def overflowing_browser(s) : Widget::TextBrowser
  tb = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: s.width, height: s.height
  tb.markdown = (1..60).map { |i| "line #{i} of the long document" }.join("\n")
  s.repaint
  tb
end

# The bar's column, and the char/fg pairs painted down it.
private def bar_column(s) : Int32
  s.width - 1
end

private def column_cells(s, x) : Array({Char, Int32})
  (0...s.height).map { |y| {cell_char(s, x, y), cell_fg(s, x, y)} }
end

# A bound scroll bar is a layer that stacks *within its host* (a `QScrollBar`
# is painted inside its `QAbstractScrollArea`): folded over the host's own
# painting for its translucency, but covered by whatever paints after the
# host — a modal dialog, a sibling raised above it — where a window-level
# layer would be composited over everything at the end of the frame.
describe "ScrollBar stacking" do
  it "shows the themed bar as a translucent local layer over its host's edge" do
    s = headless_screen(40, 10)
    with_theme(Crysterm::CSS::Theme.dark) do
      tb = overflowing_browser s
      s.repaint
      bar = tb.vertical_scrollbar
      bar.style.z_index.should eq 5
      bar.local_layer?.should be_true
      x = bar_column s
      cell_char(s, x, 0).should_not eq ' '
      # Folded at the layer's opacity: the glyph color is a blend, neither the
      # bar's own `--muted` nor the host's text color.
      cell_fg(s, x, 0).should_not eq bar.style.fg
      cell_fg(s, x, 0).should_not eq cell_fg(s, 0, 0)
    end
  end

  it "is covered by a modal MessageBox opened over it" do
    s = headless_screen(40, 10)
    with_theme(Crysterm::CSS::Theme.dark) do
      overflowing_browser s
      s.repaint
      x = bar_column s
      before = column_cells s, x
      mb = Widget::MessageBox.new parent: s, top: 2, left: 20, width: 20, height: 6
      mb.open("Save changes?", ["Save", "Don't save", "Cancel"]) { }
      s.repaint
      (2...8).each do |y|
        cell_char(s, x, y).should eq ' '
        cell_bg(s, x, y).should eq cell_bg(s, x - 1, y)
      end
      # Where the dialog does not reach, the bar is as it was.
      after = column_cells s, x
      {0, 1, 8, 9}.each { |y| after[y].should eq before[y] }
    end
  end

  it "is covered by a sibling raised above its host, which takes the clicks there" do
    s = headless_screen(40, 10)
    with_theme(Crysterm::CSS::Theme.dark) do
      tb = overflowing_browser s
      cover = Widget::Button.new parent: s, top: 3, left: 30, width: 10, height: 3, text: "over"
      cover.to_front
      s.repaint
      x = bar_column s
      (3...6).each do |y|
        cell_char(s, x, y).should eq ' '
        cell_bg(s, x, y).should eq cover.style.bg
      end
      s.widget_at(x, 4).should be cover
      s.widget_at(x, 1).should be tb.vertical_scrollbar
    end
  end

  it "stays under a window-level layer above its host" do
    s = headless_screen(40, 10)
    with_theme(Crysterm::CSS::Theme.dark) do
      s.stylesheet = ".ov { z-index: 10; background-color: #335577; }"
      overflowing_browser s
      ov = Widget::Box.new parent: s, top: 3, left: 30, width: 10, height: 3
      ov.add_css_class "ov"
      s.repaint
      x = bar_column s
      (3...6).each do |y|
        cell_char(s, x, y).should eq ' '
        cell_bg(s, x, y).should eq 0x335577
      end
      cell_char(s, x, 0).should_not eq ' '
    end
  end
end
