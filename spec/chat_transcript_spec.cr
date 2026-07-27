require "./spec_helper"

include Crysterm

# `Widget::Chat::Transcript` (CHATBOX.md Phase 0+1): the append/mutate/collapse
# entry model, per-kind prefix glyphs, and sticky-bottom auto-scroll.

private alias Transcript = Crysterm::Widget::Chat::Transcript
private alias ChatGlyphs = Crysterm::Chat::Glyphs

describe Crysterm::Widget::Chat::Transcript do
  it "append renders the prefix glyph and the text" do
    s = headless_screen(60, 20, default_quit_keys: true)
    t = Transcript.new parent: s, top: 0, left: 0, width: 50, height: 10

    t.append Transcript::Entry.new(:prose, "Hello world")

    t.entries.size.should eq 1
    t.line(0).should contain ChatGlyphs::BULLET
    t.line(0).should contain "Hello world"

    t.append :tool_call, "Bash(ls)", state: :ok
    t.line(1).should contain ChatGlyphs::BULLET
    t.line(1).should contain "Bash(ls)"
  end

  it "update_last mutates the tail entry in place without growing the entry list" do
    s = headless_screen(60, 20, default_quit_keys: true)
    t = Transcript.new parent: s, top: 0, left: 0, width: 50, height: 10

    e = Transcript::Entry.new(:tool_call, "Bash(npm test)", state: :running)
    t.append e

    # Streaming growth: the same entry object gains lines and settles.
    e.text = "Bash(npm test)\n120 tests passed"
    e.state = :ok
    t.update_last e

    t.entries.size.should eq 1
    all = t.lines.join('\n')
    all.should contain "Bash(npm test)"
    all.should contain "120 tests passed"

    # A rewrite (not pure growth) also lands in place.
    e.text = "Bash(npm test) failed"
    e.state = :fail
    t.update_last e
    t.entries.size.should eq 1
    t.lines.join('\n').should contain "Bash(npm test) failed"
    t.lines.join('\n').should_not contain "120 tests passed"
  end

  it "collapses over-threshold bodies behind a marker and expands losslessly" do
    s = headless_screen(60, 20, default_quit_keys: true)
    t = Transcript.new parent: s, top: 0, left: 0, width: 50, height: 10

    body = (1..15).map { |i| "row #{i}" }.join('\n')
    e = Transcript::Entry.new(:tool_result, body)
    t.append e

    # Default threshold 10: rows 11..15 hidden behind the marker.
    collapsed = t.lines.join('\n')
    collapsed.should contain "#{ChatGlyphs::ELLIPSIS} +5 lines"
    collapsed.should contain "row 10"
    collapsed.should_not contain "row 11"

    t.toggle_collapse(0).should be_false
    expanded = t.lines.join('\n')
    expanded.should_not contain "+5 lines"
    expanded.should contain "row 15"

    # Toggle back (by entry object this time): marker returns, and the full
    # body is still retained on the entry.
    t.toggle_collapse(e).should be_true
    t.lines.join('\n').should contain "#{ChatGlyphs::ELLIPSIS} +5 lines"
    e.full_text.should eq body
  end

  it "indents nested tool results by depth" do
    s = headless_screen(60, 20, default_quit_keys: true)
    t = Transcript.new parent: s, top: 0, left: 0, width: 50, height: 10

    t.append :tool_result, "top-level result"
    t.append :tool_result, "nested result", depth: 1

    t.line(0).should start_with "  #{ChatGlyphs::RESULT}  top-level result"
    t.line(1).should start_with "    #{ChatGlyphs::RESULT}  nested result"
  end

  it "sticks to the bottom when at the bottom, and does not yank a scrolled-up view" do
    s = headless_screen(60, 20, default_quit_keys: true)
    t = Transcript.new parent: s, top: 0, left: 0, width: 30, height: 5

    20.times { |i| t.append :prose, "line #{i}" }
    s.render
    t.scroll_percent.should be >= 1.0 # following the tail

    t.scroll -3 # the user scrolls up to read back
    s.render
    (t.scroll_percent < 1.0).should be_true

    5.times { |i| t.append :prose, "more #{i}" } # must NOT yank the view down
    s.render
    (t.scroll_percent < 1.0).should be_true

    t.scroll_percent = 1.0 # return to the bottom
    s.render
    3.times { |i| t.append :prose, "tail #{i}" }
    s.render
    t.scroll_percent.should be >= 1.0 # following again
  end

  it "pins the kind/state -> glyph and color mapping" do
    Transcript.prefix_glyph(:prose).should eq ChatGlyphs::BULLET
    Transcript.prefix_glyph(:tool_call).should eq ChatGlyphs::BULLET
    Transcript.prefix_glyph(:todo).should eq ChatGlyphs::BULLET
    Transcript.prefix_glyph(:tool_result).should eq ChatGlyphs::RESULT
    Transcript.prefix_glyph(:error).should eq ChatGlyphs::FAIL
    Transcript.prefix_glyph(:diff).should eq ""

    Transcript.state_color(:tool_call, :running).should eq "cyan"
    Transcript.state_color(:tool_call, :ok).should eq "green"
    Transcript.state_color(:tool_call, :fail).should eq "red"
    Transcript.state_color(:error).should eq "red"
    Transcript.state_color(:prose).should be_nil

    # The glyph constants themselves are part of the contract (Phase 0).
    ChatGlyphs::BULLET.should eq "⏺"
    ChatGlyphs::RESULT.should eq "⎿"
    ChatGlyphs::FAIL.should eq "✗"
    ChatGlyphs::OK.should eq "✓"
    ChatGlyphs::ELLIPSIS.should eq "…"
    ChatGlyphs::TREE_BRANCH.should eq "├"
    ChatGlyphs::TREE_LAST.should eq "└"
  end
end
