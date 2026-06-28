require "./spec_helper"

include Crysterm

private def headless_screen
  Crysterm::Screen.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

private def tagged_box
  box = Widget::Box.new parent: headless_screen
  box.parse_tags = true
  box
end

# Drop-malformed policy (todoc Q6): anything that is not a recognized tag is
# stripped, while the surrounding valid text is preserved. Use {open}/{close}/
# {escape} to emit literal braces.
describe "Widget#_parse_tags malformed input" do
  it "drops a stray { but keeps the surrounding text" do
    tagged_box._parse_tags("a{b").should eq "ab"
  end

  it "drops a stray } but keeps the surrounding text" do
    tagged_box._parse_tags("a}b").should eq "ab"
  end

  it "drops a syntactically-valid but unknown tag" do
    tagged_box._parse_tags("x{bogus}y").should eq "xy"
  end

  it "drops an unknown closing tag without corrupting state" do
    # The unknown {/bogus} must not pop the {red-fg} off the nesting stack.
    box = tagged_box
    out = box._parse_tags("{red-fg}hi{/bogus}there{/red-fg}")
    out.should contain "hithere"
    out.should start_with "\e[" # opened red-fg
    out.should end_with "m"     # closed back to default
  end

  it "leaves brace-free text untouched" do
    tagged_box._parse_tags("hello world").should eq "hello world"
  end

  it "still parses {open}/{close} into literal braces" do
    box = tagged_box
    box._parse_tags("{open}").should eq "{"
    box._parse_tags("{close}").should eq "}"
  end

  it "still parses a recognized tag into its SGR" do
    box = tagged_box
    out = box._parse_tags("{bold}hi{/bold}")
    out.should contain "hi"
    out.should contain "\e[1m" # bold on
  end

  # A *recognized* closing tag with no matching opening tag leaves the nesting
  # stack empty; the close handler must not raise (Crystal's `Array#pop` would).
  it "does not raise on a recognized closing tag with no matching open" do
    box = tagged_box
    out = box._parse_tags("{/bold}")
    out.should contain "\e[" # emitted the bold "off" SGR rather than crashing
  end

  it "does not raise on an unmatched fg closing tag, keeping surrounding text" do
    box = tagged_box
    out = box._parse_tags("hi{/red-fg}there")
    out.should contain "hi"
    out.should contain "there"
  end

  it "does not raise on more closes than opens" do
    box = tagged_box
    out = box._parse_tags("{bold}x{/bold}{/bold}")
    out.should contain "x"
  end
end

# `{left}`/`{center}`/`{right}` are line-alignment tags consumed later by
# `#_wrap_content`, not attribute tags. They carry no SGR, so the drop-malformed
# policy used to treat them as "unknown" and strip them in `_parse_tags` — which
# silently disabled `{center}…{/center}` alignment (the content rendered
# left-aligned). They must instead pass through parsing verbatim, like `{|}`.
describe "Widget#_parse_tags alignment tags" do
  it "preserves {center}…{/center} verbatim (so wrapping can center)" do
    tagged_box._parse_tags("{center}Hi{/center}").should eq "{center}Hi{/center}"
  end

  it "preserves {left}/{right} opener and closer verbatim" do
    tagged_box._parse_tags("{right}R{/right}").should eq "{right}R{/right}"
    tagged_box._parse_tags("{left}L{/left}").should eq "{left}L{/left}"
  end

  it "still parses attribute tags nested inside an alignment tag" do
    out = tagged_box._parse_tags("{center}{bold}Hi{/bold}{/center}")
    out.should eq "{center}\e[1mHi\e[22m{/center}"
  end

  it "actually centers content set with {center}…{/center}" do
    box = Widget::Box.new parent: headless_screen, width: 20, height: 3
    box.parse_tags = true
    box.set_content "{center}Hi{/center}"
    # 20-column interior: "Hi" centered => 9 cells + "Hi" + 9 cells.
    box._clines.lines.should eq ["         Hi         "]
  end

  it "right-aligns content set with {right}…{/right}" do
    box = Widget::Box.new parent: headless_screen, width: 12, height: 2
    box.parse_tags = true
    box.set_content "{right}R{/right}"
    box._clines.lines.should eq ["           R"]
  end

  it "centers every row of multi-line {center} content" do
    box = Widget::Box.new parent: headless_screen, width: 12, height: 4
    box.parse_tags = true
    box.set_content "{center}A\nBB{/center}"
    box._clines.lines.should eq ["     A      ", "     BB     "]
  end

  # An alignment tag nested INSIDE an attribute tag is preceded/followed by SGR
  # after `_parse_tags` (`{bold}{center}…{/center}{/bold}` ->
  # `\e[1m{center}…{/center}\e[22m`). `#_wrap_content` used to match the alignment
  # tag only at the absolute string edge, so the SGR-wrapped form was missed: the
  # content rendered left-aligned AND the literal `{center}`/`{/center}` text
  # leaked into the wrapped output. It must center identically to the un-nested
  # form, with the surrounding SGR preserved.
  it "centers content when {center} is nested inside an attribute tag" do
    box = Widget::Box.new parent: headless_screen, width: 12, height: 3
    box.parse_tags = true
    box.set_content "{bold}{center}Hi{/center}{/bold}"
    # 12-col interior, "Hi" centered => 5 + Hi + 5, with the SGR kept around it
    # and no literal `{center}`/`{/center}` text remaining.
    box._clines.lines.should eq ["     \e[1mHi\e[22m     "]
  end

  it "right-aligns content when {right} is nested inside an attribute tag" do
    box = Widget::Box.new parent: headless_screen, width: 12, height: 2
    box.parse_tags = true
    box.set_content "{bold}{right}R{/right}{/bold}"
    box._clines.lines.should eq ["           \e[1mR\e[22m"]
  end
end
