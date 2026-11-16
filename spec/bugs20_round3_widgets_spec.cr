require "./spec_helper"

private def table_rows
  [["Name", "Email"], ["Alice", "alice@example.com"], ["Bob", "bob@example.com"]]
end

private def sortable_table(s, **opts)
  Crysterm::Widget::ListTable.new(**opts, parent: s, top: 0, left: 0, height: 8,
    rows: [["Name", "N"], ["beta", "2"], ["alpha", "1"], ["gamma", "3"], ["delta", "4"]])
end

describe "Table with an explicit width" do
  it "keeps a percent width across rebuilds and renders" do
    s = headless_screen(80, 24)
    t = Crysterm::Widget::Table.new parent: s, top: 0, left: 0, width: "50%",
      rows: table_rows, style: Crysterm::Style.new(border: true)
    t.awidth.should eq 40

    t.rows = table_rows + [["Carol", "carol@example.com"]]
    s.repaint
    t.awidth.should eq 40

    t[1, 0] = "Alicia"
    s.repaint
    t.awidth.should eq 40
  ensure
    s.try &.destroy
  end

  it "fills a percent width with its columns" do
    s = headless_screen(80, 24)
    t = Crysterm::Widget::Table.new parent: s, top: 0, left: 0, width: "50%",
      rows: table_rows, style: Crysterm::Style.new(border: true)
    s.repaint
    t.row_width.should eq t.awidth - t.ihorizontal
  ensure
    s.try &.destroy
  end

  it "does not grow a fixed width that is too small for the columns" do
    s = headless_screen(80, 24)
    t = Crysterm::Widget::Table.new parent: s, top: 0, left: 0, width: 12,
      rows: table_rows, style: Crysterm::Style.new(border: true)
    s.repaint
    t.awidth.should eq 12
    t.rows = table_rows
    s.repaint
    t.awidth.should eq 12
    (t.row_width > 12).should be_true
  ensure
    s.try &.destroy
  end

  it "still sizes to its content without one" do
    s = headless_screen(80, 24)
    t = Crysterm::Widget::Table.new parent: s, top: 0, left: 0,
      rows: table_rows, style: Crysterm::Style.new(border: true)
    s.repaint
    t.awidth.should eq t.row_width + t.ihorizontal
  ensure
    s.try &.destroy
  end
end

describe "ListTable sorting" do
  it "keeps the current row on its record" do
    s = headless_screen(40, 12)
    lt = sortable_table s
    s.repaint
    lt.current_index = 1 # "beta"

    lt.sort_by_column 0
    lt.rows[lt.current_index][0].should eq "beta"
    lt.current_index.should eq 2

    lt.sort_by_column 0, :descending
    lt.rows[lt.current_index][0].should eq "beta"
    lt.current_index.should eq 3
  ensure
    s.try &.destroy
  end

  it "keeps the multi-selection on its records" do
    s = headless_screen(40, 12)
    lt = sortable_table s
    lt.selection_mode = Crysterm::Mixin::ItemView::SelectionMode::MultiSelection
    s.repaint
    lt.add_to_selection 1 # "beta"
    lt.add_to_selection 3 # "gamma"

    lt.sort_by_column 0
    lt.selected_indices.to_a.sort.map { |i| lt.rows[i][0] }.should eq ["beta", "gamma"]
  ensure
    s.try &.destroy
  end

  it "follows the current record when new data arrives under an active sort" do
    s = headless_screen(40, 12)
    lt = sortable_table s
    s.repaint
    lt.sort_by_column 0
    lt.current_index = 3 # "delta"
    lt.rows[3][0].should eq "delta"

    lt.rows = [["Name", "N"], ["delta", "4"], ["zeta", "9"], ["alpha", "1"], ["beta", "2"]]
    lt.rows[lt.current_index][0].should eq "delta"
  ensure
    s.try &.destroy
  end

  it "leaves the selection in place when the order does not change" do
    s = headless_screen(40, 12)
    lt = sortable_table s
    s.repaint
    lt.sort_by_column 0
    lt.current_index = 4
    lt.sort_by_column 0
    lt.current_index.should eq 4
  ensure
    s.try &.destroy
  end
end

describe "InputDialog re-opened while a prompt is up" do
  it "cancels the running prompt once and answers the new one" do
    s = headless_screen(60, 24)
    d = Crysterm::Widget::InputDialog.new parent: s
    first = [] of String?
    second = [] of String?
    rejected = 0
    d.on(Crysterm::Event::Rejected) { rejected += 1 }

    d.open("Name:") { |v| first << v }
    d.open("Email:") { |v| second << v }

    first.should eq [nil]
    second.empty?.should be_true
    rejected.should eq 1
    d.visible?.should be_true
    d.modal?.should be_true

    d.line_edit.value = "a@b"
    d.accept

    second.should eq ["a@b"]
    first.should eq [nil]
    d.visible?.should be_false
    d.modal?.should be_false
  ensure
    s.try &.destroy
  end

  it "keeps a single OK/Cancel wiring after a re-open" do
    s = headless_screen(60, 24)
    d = Crysterm::Widget::InputDialog.new parent: s
    answers = [] of String?
    finished = 0
    d.on(Crysterm::Event::Finished) { finished += 1 }

    d.open("One:") { |v| answers << v }
    d.open("Two:") { |v| answers << v }
    finished.should eq 1

    d.reject
    answers.should eq [nil, nil]
    finished.should eq 2
  ensure
    s.try &.destroy
  end
end

describe "Action submenu editing" do
  it "notifies on add, insert, remove and clear" do
    a = Crysterm::Action.new "Recent"
    one = Crysterm::Action.new "One"
    two = Crysterm::Action.new "Two"
    changed = 0
    a.on(Crysterm::Event::Changed) { changed += 1 }

    a.add_menu_action(one).same?(one).should be_true
    a.insert_menu_action 0, two
    changed.should eq 2
    a.menu.try(&.map(&.text)).should eq ["Two", "One"]

    # Already held: nothing changes.
    a.add_menu_action one
    changed.should eq 2

    a.remove_menu_action(two).same?(two).should be_true
    a.remove_menu_action(two).nil?.should be_true
    changed.should eq 3

    a.clear_menu_actions
    a.clear_menu_actions
    changed.should eq 4
    a.menu?.should be_false
  end

  it "installs and withdraws the accelerator of a submenu action on a MenuBar" do
    s = headless_screen(80, 24)
    bar = Crysterm::Widget::MenuBar.new parent: s, top: 0, left: 0, width: "100%", height: 1
    file = bar.add_menu "File"
    recent = file.add_submenu "Recent"
    nested = Crysterm::Action.new "Nested"
    recent.add_menu_action nested

    copy = Crysterm::Action.new "Copy", shortcut: ::Tput::Key::CtrlC
    fired = 0
    copy.on(Crysterm::Event::Triggered) { fired += 1 }

    # Two levels down: neither the menu nor the bar holds the owner directly.
    nested.add_menu_action copy
    s.emit Crysterm::Event::KeyPress.new('\0', ::Tput::Key::CtrlC)
    fired.should eq 1

    nested.remove_menu_action copy
    s.emit Crysterm::Event::KeyPress.new('\0', ::Tput::Key::CtrlC)
    fired.should eq 1
  ensure
    s.try &.destroy
  end

  it "withdraws the accelerators of a replaced submenu list" do
    s = headless_screen(80, 24)
    bar = Crysterm::Widget::MenuBar.new parent: s, top: 0, left: 0, width: "100%", height: 1
    file = bar.add_menu "File"
    copy = Crysterm::Action.new "Copy", shortcut: ::Tput::Key::CtrlC
    fired = 0
    copy.on(Crysterm::Event::Triggered) { fired += 1 }
    recent = file.add_submenu "Recent", [copy]

    recent.menu = [Crysterm::Action.new("Other")]
    s.emit Crysterm::Event::KeyPress.new('\0', ::Tput::Key::CtrlC)
    fired.should eq 0
  ensure
    s.try &.destroy
  end

  it "keeps the accelerator of an action the bar still presents elsewhere" do
    s = headless_screen(80, 24)
    bar = Crysterm::Widget::MenuBar.new parent: s, top: 0, left: 0, width: "100%", height: 1
    copy = Crysterm::Action.new "Copy", shortcut: ::Tput::Key::CtrlC
    fired = 0
    copy.on(Crysterm::Event::Triggered) { fired += 1 }
    file = bar.add_menu "File"
    recent = file.add_submenu "Recent", [copy]
    bar.add_menu "Edit", [copy]

    recent.remove_menu_action copy
    s.emit Crysterm::Event::KeyPress.new('\0', ::Tput::Key::CtrlC)
    fired.should eq 1
  ensure
    s.try &.destroy
  end

  it "stops watching the actions of a removed menu" do
    s = headless_screen(80, 24)
    bar = Crysterm::Widget::MenuBar.new parent: s, top: 0, left: 0, width: "100%", height: 1
    file = bar.add_menu "File"
    recent = file.add_submenu "Recent"
    copy = Crysterm::Action.new "Copy", shortcut: ::Tput::Key::CtrlC
    fired = 0
    copy.on(Crysterm::Event::Triggered) { fired += 1 }

    bar.remove_item 0
    recent.add_menu_action copy
    s.emit Crysterm::Event::KeyPress.new('\0', ::Tput::Key::CtrlC)
    fired.should eq 0
  ensure
    s.try &.destroy
  end
end

describe "Chat::Transcript#update_last with a different entry" do
  it "unlinks the replaced entry from its parent" do
    s = headless_screen(60, 20)
    t = Crysterm::Widget::Chat::Transcript.new parent: s, top: 0, left: 0, width: 50, height: 10
    call = t.append :tool_call, "run"
    t.append :tool_result, "old", parent: call
    fresh = Crysterm::Widget::Chat::Transcript::Entry.new :tool_result, "new", parent: call

    t.update_last fresh

    call.children.size.should eq 1
    call.children[0].same?(fresh).should be_true
    fresh.last_child?.should be_true
    t.entries.size.should eq 2
    t.entries[1].same?(fresh).should be_true
    t.toggle_collapse(fresh).nil?.should be_false
  ensure
    s.try &.destroy
  end

  it "redraws the sibling left last under the old parent" do
    s = headless_screen(60, 20)
    t = Crysterm::Widget::Chat::Transcript.new parent: s, top: 0, left: 0, width: 50, height: 10
    call = t.append :tool_call, "run"
    t.append :notice, "first", parent: call
    t.append :notice, "second", parent: call
    branch = Crysterm::Chat::Glyphs::TREE_BRANCH
    t.content.includes?(branch).should be_true

    # The tail leaves the subtree: "first" is the only, and so the last, child.
    t.update_last Crysterm::Widget::Chat::Transcript::Entry.new(:prose, "done")

    call.children.size.should eq 1
    t.content.includes?(branch).should be_false
    t.content.includes?("second").should be_false
    t.content.includes?("done").should be_true
  ensure
    s.try &.destroy
  end

  it "keeps the same-object streaming path" do
    s = headless_screen(60, 20)
    t = Crysterm::Widget::Chat::Transcript.new parent: s, top: 0, left: 0, width: 50, height: 10
    call = t.append :tool_call, "run"
    tail = t.append :tool_result, "a", parent: call
    tail.text = "a\nb"
    t.update_last tail
    call.children.size.should eq 1
    t.content.includes?("b").should be_true
  ensure
    s.try &.destroy
  end
end

describe "column padding by display width" do
  it "pads wide text by the columns it takes" do
    Crysterm::Formatting.ljust("日本", 6, true).should eq "日本  "
    Crysterm::Formatting.ljust("ab", 6, true).should eq "ab    "
    Crysterm::Formatting.ljust("abcdefgh", 6, true).should eq "abcdefgh"
  end

  it "measures the unescaped text of an escaped string" do
    raw = "a{b}"
    esc = Crysterm::Widget.escape_tags raw
    Crysterm::Formatting.ljust(esc, 6, true, raw).should eq "#{esc}  "
  end

  it "keeps the Mutt sidebar count column for a wide name" do
    s = headless_screen(60, 20)
    sb = Crysterm::Widget::Mutt::Sidebar.new(
      [Crysterm::Widget::Mutt::Mailbox.new("INBOX", 3), Crysterm::Widget::Mutt::Mailbox.new("受信トレイ", 3)],
      parent: s, top: 0, left: 0, width: 20, height: 5)
    ascii = sb.format_row sb.mailboxes[0], 0
    wide = sb.format_row sb.mailboxes[1], 1
    sb.str_width(wide).should eq sb.str_width(ascii)

    long = Crysterm::Widget::Mutt::Mailbox.new("受信トレイ受信トレイ受信トレイ", 3)
    sb.str_width(sb.format_row(long, 2)).should eq sb.str_width(ascii)
  ensure
    s.try &.destroy
  end

  it "sizes Pine key prompt cells by display width" do
    s = headless_screen(60, 20)
    prompt = Crysterm::Widget::Pine::KeyPrompt.new("保存?",
      [Crysterm::Widget::Pine::KeyPrompt::Choice.new("Y", "はい")], parent: s)
    prompt.cells[0].width.should eq prompt.str_width("保存?") + 1
    prompt.cells[1].width.should eq prompt.str_width("はい") + 6
  ensure
    s.try &.destroy
  end
end

describe "Graph::Scale.span_top" do
  it "keeps a range above its minimum" do
    Crysterm::Widget::Graph::Scale.span_top(0.0, 5.0).should eq 5.0
    Crysterm::Widget::Graph::Scale.span_top(2.0, 2.0).should eq 3.0
    Crysterm::Widget::Graph::Scale.span_top(-4.0, -9.0).should eq -3.0
  end

  it "opens a span where one unit is below Float64 resolution" do
    (Crysterm::Widget::Graph::Scale.span_top(1e17, 1e17) > 1e17).should be_true
    (Crysterm::Widget::Graph::Scale.span_top(-1e300, -1e300) > -1e300).should be_true
    Crysterm::Widget::Graph::Scale.span_top(1e308, 1e308).finite?.should be_true
  end

  it "plots flat data at a huge magnitude" do
    s = headless_screen(60, 20)
    chart = Crysterm::Widget::Graph::LineChart.new parent: s, top: 0, left: 0, width: 50, height: 15
    chart.add_line "flat", [{1e17, 1e17}, {1e17, 1e17}]
    s.repaint
  ensure
    s.try &.destroy
  end
end
