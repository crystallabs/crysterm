require "./spec_helper"

include Crysterm

# `Crysterm::Chat::Diff` (the unified-diff formatter) and
# `Widget::Chat::Dialogs` (chat-flavored confirm/notice presenters over
# `Question`/`Message`).

private alias ChatDiff = Crysterm::Chat::Diff
private alias ChatDialogs = Crysterm::Widget::Chat::Dialogs
private alias ChatGlyphs = Crysterm::Chat::Glyphs

private MULTI_HUNK = <<-DIFF
  diff --git a/foo.cr b/foo.cr
  index 1111111..2222222 100644
  --- a/foo.cr
  +++ b/foo.cr
  @@ -1,3 +1,3 @@
   module Foo
  -  VERSION = "0.1"
  +  VERSION = "0.2"
   end
  @@ -10,3 +10,4 @@ def bar
     a
     b
  +  c
     d
  DIFF

describe Crysterm::Chat::Diff do
  it "classifies a multi-hunk diff line by line" do
    lines = ChatDiff.parse MULTI_HUNK

    lines.count(&.kind.file?).should eq 3 # diff --git, ---, +++
    lines.count(&.kind.meta?).should eq 1 # index …
    lines.count(&.kind.hunk?).should eq 2
    lines.count(&.kind.add?).should eq 2
    lines.count(&.kind.del?).should eq 1
    lines.count(&.kind.context?).should eq 5

    lines[4].kind.hunk?.should be_true
    lines[4].text.should eq "@@ -1,3 +1,3 @@"
    lines[6].text.should eq "-  VERSION = \"0.1\""
    lines[7].text.should eq "+  VERSION = \"0.2\""
  end

  it "styles adds green, dels red, hunk headers cyan, file headers bold" do
    styled = ChatDiff.format MULTI_HUNK

    styled.should contain "{green-fg}+  VERSION = \"0.2\"{/green-fg}"
    styled.should contain "{red-fg}-  VERSION = \"0.1\"{/red-fg}"
    styled.should contain "{cyan-fg}@@ -1,3 +1,3 @@{/cyan-fg}"
    styled.should contain "{bold}--- a/foo.cr{/bold}"
    styled.should contain "{bold}+++ b/foo.cr{/bold}"
    # Context lines pass through unstyled.
    styled.should contain "\n module Foo\n"
  end

  it "exposes the add/del CSS classes per line" do
    lines = ChatDiff.parse MULTI_HUNK
    lines.find!(&.kind.add?).css_class.should eq ChatGlyphs::CLASS_DIFF_ADD
    lines.find!(&.kind.del?).css_class.should eq ChatGlyphs::CLASS_DIFF_DEL
    lines.find!(&.kind.hunk?).css_class.should be_nil
    lines.find!(&.kind.context?).css_class.should be_nil
  end

  it "does not mistake a deleted '--'-prefixed line for a file header" do
    diff = <<-DIFF
      @@ -1,2 +1,1 @@
      -- item
       keep
      DIFF

    lines = ChatDiff.parse diff
    lines[1].kind.del?.should be_true
    lines[1].text.should eq "-- item"
    lines[2].kind.context?.should be_true
  end

  it "escapes braces so diff content cannot inject tags" do
    diff = <<-DIFF
      @@ -1,1 +1,1 @@
      -puts "{old}"
      +puts "{new}"
      DIFF

    styled = ChatDiff.format diff
    styled.should contain "{green-fg}+puts \"{open}new{close}\"{/green-fg}"
    styled.should_not contain "{old}"
  end

  it "trims context runs down to N lines around each change" do
    diff = <<-DIFF
      @@ -1,8 +1,8 @@
       c1
       c2
       c3
      -old
      +new
       c4
       c5
       c6
       c7
      DIFF

    lines = ChatDiff.lines diff, context: 1
    text = lines.join '\n', &.text
    text.should contain "c3"
    text.should contain "c4"
    text.should_not contain "c2"
    text.should_not contain "c5"
    text.should contain "-old"
    text.should contain "+new"

    # One elision marker per trimmed run, counting the dropped lines.
    elisions = lines.select(&.kind.elision?)
    elisions.size.should eq 2
    elisions[0].text.should eq "#{ChatGlyphs::ELLIPSIS} 2 unchanged lines"
    elisions[1].text.should eq "#{ChatGlyphs::ELLIPSIS} 3 unchanged lines"

    # Without trimming, everything survives.
    ChatDiff.lines(diff).count(&.kind.context?).should eq 7
  end

  it "keeps the no-trailing-newline marker attached through parse and trim" do
    diff = <<-DIFF
      --- a/x
      +++ b/x
      @@ -1,1 +1,1 @@
      -old
      +new
      \\ No newline at end of file
      DIFF

    lines = ChatDiff.parse diff
    lines.last.kind.meta?.should be_true
    lines.last.text.should eq "\\ No newline at end of file"

    # Trimming never drops it.
    trimmed = ChatDiff.lines diff, context: 0
    trimmed.last.text.should eq "\\ No newline at end of file"
    ChatDiff.entry_text(diff).should contain "No newline"
  end

  it "classifies binary markers" do
    diff = <<-DIFF
      diff --git a/img.png b/img.png
      Binary files a/img.png and b/img.png differ
      DIFF

    lines = ChatDiff.parse diff
    lines[1].kind.binary?.should be_true
    ChatDiff.format(diff).should contain "{bold}Binary files a/img.png and b/img.png differ{/bold}"
  end

  it "handles an empty diff" do
    ChatDiff.parse("").should be_empty
    ChatDiff.format("").should eq ""
    ChatDiff.entry_text("").should eq ""
    ChatDiff.lines("", context: 1).should be_empty
  end

  it "entry_text returns the plain lines for a transcript diff entry" do
    ChatDiff.entry_text(MULTI_HUNK).should eq MULTI_HUNK
  end
end

describe Crysterm::Widget::Chat::Dialogs do
  it "confirm renders headless and returns the chosen answer" do
    s = headless_screen 80, 24
    answer = nil.as(Bool?)
    q = ChatDialogs.confirm(s, "Proceed?") { |a| answer = a }
    s.render

    e = Crysterm::Event::KeyPress.new 'y'
    s.emit e
    answer.should be_true
    e.accepted?.should be_true
    q.accepted?.should be_true
  end

  it "confirm answers false on 'n'" do
    s = headless_screen 80, 24
    answer = nil.as(Bool?)
    ChatDialogs.confirm(s, "Proceed?") { |a| answer = a }

    s.emit Crysterm::Event::KeyPress.new 'n'
    answer.should be_false
  end

  it "confirm_diff shows the styled preview and delivers the answer" do
    s = headless_screen 80, 24
    answer = nil.as(Bool?)
    q = ChatDialogs.confirm_diff(s, "Apply this edit?", MULTI_HUNK, context: 1) { |a| answer = a }
    s.render

    q.content.should contain "Apply this edit?"
    q.content.should contain "{green-fg}+  VERSION = \"0.2\"{/green-fg}"
    q.content.should contain "{red-fg}-  VERSION = \"0.1\"{/red-fg}"

    s.emit Crysterm::Event::KeyPress.new '\r', ::Tput::Key::Enter
    answer.should be_true
  end

  it "choose delivers nil on Escape dismissal" do
    s = headless_screen 80, 24
    picked = :unset.as(Symbol | Int32?)
    ChatDialogs.choose(s, "Allow?", ["Yes", "Yes, always", "No"]) { |idx| picked = idx }
    s.render

    e = Crysterm::Event::KeyPress.new '\0', ::Tput::Key::Escape
    s.emit e
    e.accepted?.should be_true
    picked.should be_nil
  end

  it "notice renders and dismisses on the next keypress" do
    s = headless_screen 80, 24
    m = ChatDialogs.notice s, "Saved.", Time::Span.zero
    s.render

    e = Crysterm::Event::KeyPress.new 'x'
    s.emit e
    e.accepted?.should be_true
    m.accepted?.should be_true
  end
end
