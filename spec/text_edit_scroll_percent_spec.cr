require "./spec_helper"

include Crysterm

private TEXT = (1..50).map { |i| "line #{i}" }.join("\n")

# `TextEdit`/`PlainTextEdit` scroll as a pure viewport (`child_offset` stays
# 0), so their `scroll_percent` must span the viewport range: 0.0 at the top,
# 1.0 with the last row in view — not the cursor-row formula, under which the
# bottom of a 50-line text in a 10-row view read as 82%.
{% for klass in [Widget::TextEdit, Widget::PlainTextEdit] %}
  describe "{{ klass }}#scroll_percent" do
    it "reads 0.0 at the top and 1.0 at the bottom, and round-trips through its setter" do
      s = headless_screen(30, 10)
      te = {{ klass }}.new parent: s, left: 0, top: 0, width: 30, height: 10
      te.value = TEXT # parks the caret at the end; the first paint follows it
      s.repaint
      te.cursor_pos = 0
      te.scroll_to 0
      s.repaint
      te.scroll_percent.should eq 0.0
      te.scroll_to 10_000
      s.repaint
      te.scroll_position.should eq 40 # 50 rows, 10 visible
      te.scroll_percent.should eq 1.0
      te.scroll_percent = 0.5
      s.repaint
      te.scroll_position.should eq 20
      te.scroll_percent.should eq 0.5
    end
  end
{% end %}
