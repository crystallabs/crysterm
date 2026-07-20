require "./spec_helper"

include Crysterm

private def sized_screen(width = 40, height = 10)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height, default_quit_keys: false)
end

# BUGS17 B17-06 — `_wrap_content`'s alignment-tag consumption (`{center}`/
# `{left}`/`{right}`) and `aligned_with_width`'s `{|}` right-align separator
# were gated only on `@parse_tags`, never on `@_content_no_tags`. So on a
# parse_tags-enabled widget, literal text delivered via `set_text` that
# happened to contain `{center}...{/center}` or `{|}` had those tokens
# silently consumed and the line re-aligned, breaking set_text's literal
# contract. Fixed by adding `!@_content_no_tags` to the three wrap-stage
# gates. Must assert on `pcontent` (the real/drawn lines) — `rendered_text`
# derives from the untouched fake lines and would pass even with the bug
# present.
describe "Widget set_text (no_tags) content stays literal through alignment handling (BUGS17 B17-06)" do
  it "keeps {center}/{|} tokens literal in pcontent" do
    w = Widget::Box.new parent: sized_screen, width: 30, height: 5
    w.parse_tags = true
    w.set_text "{center}x{/center}\na{|}b"
    lines = w.pcontent.split('\n')
    lines[0].should eq "{center}x{/center}"
    lines[1].should eq "a{|}b"
  end
end
