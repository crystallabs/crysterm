require "./spec_helper"

include Crysterm

private def headless_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

# `#set_text` sets content with `no_tags: true`, so even a `parse_tags = true`
# widget shows tags literally. Must survive a later cache-miss reparse (width
# change, resize, scroll, attach), which calls `process_content` with the
# default `no_tags = false` — `@_content_no_tags` is what keeps tags literal
# across those reparses.
describe "Widget#set_text keeps tags literal across reparse" do
  it "does not parse tags on a width-triggered reparse" do
    box = Widget::Box.new parent: headless_screen, width: 20, height: 3
    box.parse_tags = true
    box.set_text("{bold}hi{/bold}")

    # Initially literal: no SGR emitted, braces intact.
    box.pcontent.should contain "{bold}"
    box.pcontent.should_not contain "\e["
    box.get_content.should contain "{bold}"

    # Force a reparse by changing the widget's width.
    box.width = 10
    box.process_content

    # Still literal — the tags must not have been expanded into SGR.
    box.pcontent.should contain "{bold}"
    box.pcontent.should_not contain "\e["
    box.get_content.should contain "{bold}"
  end

  it "still parses tags for content set via set_content across reparse" do
    # Control: with the normal (tag-parsing) path, a width reparse keeps parsing.
    box = Widget::Box.new parent: headless_screen, width: 20, height: 3
    box.parse_tags = true
    box.set_content("{bold}hi{/bold}")

    box.pcontent.should contain "\e[" # opened bold

    box.width = 10
    box.process_content

    box.pcontent.should contain "\e[" # still parsed after reparse
  end
end
