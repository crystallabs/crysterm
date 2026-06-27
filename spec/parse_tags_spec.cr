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
