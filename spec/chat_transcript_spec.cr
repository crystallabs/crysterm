require "./spec_helper"

include Crysterm

# `Widget::Chat::Transcript`: the append/mutate/collapse entry model, per-kind
# prefix glyphs, the call→result tree, expand/collapse events, click-to-toggle,
# entry styling classes, and sticky-bottom auto-scroll.

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
    s.update
    t.scroll_percent.should be >= 1.0 # following the tail

    t.scroll -3 # the user scrolls up to read back
    s.update
    (t.scroll_percent < 1.0).should be_true

    5.times { |i| t.append :prose, "more #{i}" } # must NOT yank the view down
    s.update
    (t.scroll_percent < 1.0).should be_true

    t.scroll_percent = 1.0 # return to the bottom
    s.update
    3.times { |i| t.append :prose, "tail #{i}" }
    s.update
    t.scroll_percent.should be >= 1.0 # following again
  end

  it "pins the kind/state -> glyph and color mapping" do
    Transcript.prefix_glyph(:prose).should eq ChatGlyphs::BULLET
    Transcript.prefix_glyph(:tool_call).should eq ChatGlyphs::BULLET
    Transcript.prefix_glyph(:todo).should eq ChatGlyphs::BULLET
    Transcript.prefix_glyph(:notice).should eq ChatGlyphs::BULLET
    Transcript.prefix_glyph(:thinking).should eq ChatGlyphs::THINKING
    Transcript.prefix_glyph(:tool_result).should eq ChatGlyphs::RESULT
    Transcript.prefix_glyph(:error).should eq ChatGlyphs::FAIL
    Transcript.prefix_glyph(:diff).should eq ""

    # Pending swaps the bullet for the empty circle; the todo states pick
    # their checkbox mark.
    Transcript.prefix_glyph(:tool_call, :pending).should eq ChatGlyphs::PENDING
    Transcript.prefix_glyph(:todo, :pending).should eq ChatGlyphs::TODO_OPEN
    Transcript.prefix_glyph(:todo, :ok).should eq ChatGlyphs::TODO_DONE
    Transcript.prefix_glyph(:todo, :cancelled).should eq ChatGlyphs::TODO_CANCELLED

    Transcript.state_color(:tool_call, :running).should eq "cyan"
    Transcript.state_color(:tool_call, :ok).should eq "green"
    Transcript.state_color(:tool_call, :fail).should eq "red"
    Transcript.state_color(:tool_call, :cancelled).should eq "gray"
    Transcript.state_color(:tool_call, :pending).should eq "gray"
    Transcript.state_color(:error).should eq "red"
    Transcript.state_color(:notice).should eq "yellow"
    Transcript.state_color(:thinking).should eq "gray"
    Transcript.state_color(:prose).should be_nil

    # The glyph constants themselves are part of the contract.
    ChatGlyphs::BULLET.should eq "⏺"
    ChatGlyphs::RESULT.should eq "⎿"
    ChatGlyphs::THINKING.should eq "✻"
    ChatGlyphs::FAIL.should eq "✗"
    ChatGlyphs::OK.should eq "✓"
    ChatGlyphs::ELLIPSIS.should eq "…"
    ChatGlyphs::SEP.should eq " #{ChatGlyphs::MIDDOT} "
    ChatGlyphs::TREE_BRANCH.should eq "├"
    ChatGlyphs::TREE_LAST.should eq "└"
    ChatGlyphs::TREE_PIPE.should eq "│"
    ChatGlyphs::CLASS_CANCELLED.should eq "cancelled"

    # Transcript entries and tasks share one state enum (Chat::State).
    Transcript::State.should eq Crysterm::Chat::Task::State
  end

  it "renders notice and thinking entries with their prefixes" do
    s = headless_screen(60, 20, default_quit_keys: true)
    t = Transcript.new parent: s, top: 0, left: 0, width: 50, height: 10

    t.append :notice, "Context low"
    t.line(0).should contain ChatGlyphs::BULLET
    t.line(0).should contain "Context low"

    t.append :thinking, "Pondering the request"
    t.line(1).should contain ChatGlyphs::THINKING
    t.line(1).should contain "Pondering the request"
  end

  it "links results to their calls and renders the tree connectors" do
    s = headless_screen(60, 24, default_quit_keys: true)
    t = Transcript.new parent: s, top: 0, left: 0, width: 50, height: 20

    call = t.append :tool_call, "Task(agent)"
    sub1 = t.append :tool_call, "Bash(ls)", parent: call
    t.append :tool_result, "file1\nfile2", parent: sub1
    sub2 = t.append :tool_call, "Bash(pwd)", parent: call
    t.append :tool_result, "/home", parent: sub2

    # A first child auto-expands its (short-bodied) parent.
    call.collapsed.should be_false

    t.line(0).should contain "Task(agent)"
    # Appending sub2 re-spliced sub1 from `└` to `├` (and its subtree's
    # spine).
    t.line(1).should eq "  #{ChatGlyphs::TREE_BRANCH} Bash(ls)"
    t.line(2).should eq "  #{ChatGlyphs::TREE_PIPE} #{ChatGlyphs::RESULT}  file1"
    t.line(3).should eq "  #{ChatGlyphs::TREE_PIPE}    file2"
    t.line(4).should eq "  #{ChatGlyphs::TREE_LAST} Bash(pwd)"
    t.line(5).should eq "    #{ChatGlyphs::RESULT}  /home"
  end

  it "collapsing a call folds its subtree behind the marker" do
    s = headless_screen(60, 24, default_quit_keys: true)
    t = Transcript.new parent: s, top: 0, left: 0, width: 50, height: 20

    call = t.append :tool_call, "Task(agent)"
    sub1 = t.append :tool_call, "Bash(ls)", parent: call
    t.append :tool_result, "file1\nfile2", parent: sub1
    sub2 = t.append :tool_call, "Bash(pwd)", parent: call
    t.append :tool_result, "/home", parent: sub2

    t.toggle_collapse(call).should be_true
    folded = t.lines.join('\n')
    folded.should contain "Task(agent)"
    folded.should_not contain "Bash(ls)"
    folded.should_not contain "file1"
    folded.should contain "#{ChatGlyphs::ELLIPSIS} +5 lines (Ctrl+O)"
    t.lines.size.should eq 2 # header + marker

    t.toggle_collapse(call).should be_false
    unfolded = t.lines.join('\n')
    unfolded.should contain "Bash(ls)"
    unfolded.should contain "file2"
    unfolded.should contain "/home"
    unfolded.should_not contain "+5 lines"
  end

  it "emits Expanded/Collapsed with the entry index on every toggle" do
    s = headless_screen(60, 20, default_quit_keys: true)
    t = Transcript.new parent: s, top: 0, left: 0, width: 50, height: 10

    t.append :prose, "intro"
    t.append :tool_result, (1..15).join('\n') { |i| "row #{i}" }

    log = [] of {String, Int32}
    t.on(Crysterm::Event::Expanded) { |e| log << {"expand", e.index} }
    t.on(Crysterm::Event::Collapsed) { |e| log << {"collapse", e.index} }

    t.toggle_collapse(1)
    t.toggle_collapse(1)
    log.should eq [{"expand", 1}, {"collapse", 1}]
  end

  it "toggles on a click on a collapsible entry's header (Ctrl+O still works)" do
    s = headless_screen(60, 20, default_quit_keys: true)
    # Tall enough for the expanded body, so the header stays on the first row
    # (sticky-bottom would otherwise scroll it off).
    t = Transcript.new parent: s, top: 0, left: 0, width: 50, height: 16

    body = (1..15).map { |i| "row #{i}" }.join('\n')
    e = t.append :tool_result, body
    s.update

    # The collapse marker advertises the key.
    t.lines.join('\n').should contain "(Ctrl+O)"

    ox, oy = t.painted_content_origin
    click = ->(y : Int32) do
      s.dispatch_mouse ::Tput::Mouse::Event.new(
        ::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left,
        ox + 3, oy + y, source: :test)
    end

    click.call 0 # header line -> expand
    e.collapsed.should be_false
    s.update

    click.call 3 # a body line -> no toggle
    e.collapsed.should be_false

    click.call 0 # header again -> collapse
    e.collapsed.should be_true
    s.update

    # Ctrl+O toggles the most recent collapsible entry, as before.
    t.handle_chat_key_press Crysterm::Event::KeyPress.new('\u{f}', ::Tput::Key::CtrlO)
    e.collapsed.should be_false
  end

  it "carries the styling-class vocabulary and renders through class_colors" do
    s = headless_screen(60, 20, default_quit_keys: true)
    t = Transcript.new parent: s, top: 0, left: 0, width: 50, height: 10

    run = t.append :tool_call, "Bash(x)", state: :running
    t.entry_css_classes(run).should eq [ChatGlyphs::CLASS_TOOL_CALL, ChatGlyphs::CLASS_RUNNING]

    err = t.append :error, "boom"
    t.entry_css_classes(err).should eq [ChatGlyphs::CLASS_ERROR]

    long = t.append :tool_result, (1..15).join('\n') { |i| "row #{i}" }
    t.entry_css_classes(long).should contain ChatGlyphs::CLASS_COLLAPSED
    t.toggle_collapse(long)
    t.entry_css_classes(long).should_not contain ChatGlyphs::CLASS_COLLAPSED

    # The running prefix renders cyan by default; overriding the class color
    # re-renders existing entries.
    t.line(0).should contain "\e[36m"
    t.set_class_color ChatGlyphs::CLASS_RUNNING, "magenta"
    t.line(0).should contain "\e[35m"
    t.line(0).should_not contain "\e[36m"
  end

  it "invalidates the cached body on text= and on a prose_markdown flip" do
    s = headless_screen(60, 20, default_quit_keys: true)
    t = Transcript.new parent: s, top: 0, left: 0, width: 50, height: 10

    e = t.append :prose, "**alpha**"
    t.line(0).should contain "alpha"
    t.line(0).should_not contain "**"

    # `text=` must drop the cached rendering, or update_last repaints stale
    # lines.
    e.text = "**beta** grew"
    t.update_last e
    all = t.lines.join('\n')
    all.should contain "beta"
    all.should_not contain "alpha"
    all.should_not contain "**"

    # Same text, different importer decision: the cache is keyed by the
    # markdown choice, so the flip re-renders raw.
    t.prose_markdown = false
    t.update_last e
    t.lines.join('\n').should contain "**beta** grew"
  end

  it "keeps fold-marker counts exact with cached markdown bodies across toggles" do
    s = headless_screen(60, 30, default_quit_keys: true)
    t = Transcript.new parent: s, top: 0, left: 0, width: 50, height: 24

    call = t.append :tool_call, "Task(agent)"
    t.append :prose, "**one**\n\ntwo\n\nthree", parent: call
    t.append :tool_result, "r1\nr2", parent: call

    # The marker must count exactly the lines an expand reveals — computed
    # from the cached bodies, not a re-parse.
    expanded = t.lines.size
    t.toggle_collapse(call).should be_true
    t.lines.size.should eq 2 # header + marker
    t.lines.join('\n').should contain "+#{expanded - 1} lines"

    t.toggle_collapse(call).should be_false
    t.lines.size.should eq expanded
    t.lines.join('\n').should contain "three"
  end

  it "streams growth through update_last tick by tick" do
    s = headless_screen(60, 20, default_quit_keys: true)
    t = Transcript.new parent: s, top: 0, left: 0, width: 50, height: 10

    t.append :tool_call, "Bash(build)", state: :running
    buf = "Bash(build)"
    1.upto(8) do |i|
      buf += "\nout #{i}"
      t.update_last(&.text=(buf))
    end

    t.entries.size.should eq 1
    t.lines.size.should eq 9 # header + 8 streamed lines, no duplicates
    all = t.lines.join('\n')
    all.should contain "out 1"
    all.should contain "out 8"
  end

  it "maps clicks to entries past folded (zero-line) subtrees" do
    s = headless_screen(60, 30, default_quit_keys: true)
    t = Transcript.new parent: s, top: 0, left: 0, width: 50, height: 24

    call = t.append :tool_call, "Task(agent)"
    sub = t.append :tool_call, "Bash(ls)", parent: call
    t.append :tool_result, "a\nb", parent: sub
    t.toggle_collapse(call)  # sub and its result now render zero lines
    t.lines.size.should eq 2 # header + marker

    long = t.append :tool_result, (1..15).map { |i| "row #{i}" }.join('\n')
    s.update

    ox, oy = t.painted_content_origin
    s.dispatch_mouse ::Tput::Mouse::Event.new(
      ::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left,
      ox + 3, oy + 2, source: :test) # first row of `long`, past the fold
    long.collapsed.should be_false
  end

  it "imports prose bodies as markdown (opt-out per widget)" do
    s = headless_screen(60, 20, default_quit_keys: true)
    t = Transcript.new parent: s, top: 0, left: 0, width: 50, height: 10

    t.append :prose, "**bold** and plain"
    t.line(0).should_not contain "**"
    t.line(0).should contain "bold"
    t.line(0).should contain "and plain"
    t.line(0).should contain "\e[" # the emphasis arrived as styling

    t.prose_markdown = false
    t.append :prose, "**bold** and plain"
    t.line(1).should contain "**bold** and plain"
  end
end
