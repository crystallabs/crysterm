require "./spec_helper"

include Crysterm

# The widget-subclass parity/overlap/constructor cleanups:
#
# * §2.5 `placeholder_text` hoisted to `Mixin::TextEditing`; `validator` moved
#   from the prompt dialog onto `LineEdit`; `DateTimeEdit` gained
#   `#date`/`#time` + bounds; `Table` gained a real cell model; the `Float64`
#   range signal (`Event::DoubleRangeChanged`) now exists and is emitted;
#   `Mixin::ActionBar#items` answers with label strings like every other
#   `#items`.
# * §2.6 `ProgressBar` is a read-only, non-focusable indicator by default.
# * §2.7 `Widget::Input` → `AbstractInteractive`; `Message`/`Question` →
#   `MessageBox`; `Prompt` → `InputDialog`; `ListBar` → `CommandBar`; one
#   dialog presentation verb, `#open`.
# * §2.8 `step:` doublet, `percent:` twin, `scrollbar:` legacy arg and the
#   two-arg `set_*` pairs are gone.

describe "§2.5 placeholder_text is a Mixin::TextEditing property" do
  it "is available on all three text widgets, not just LineEdit" do
    s = headless_screen(80, 24)
    le = Widget::LineEdit.new parent: s, width: 20, height: 1, placeholder_text: "name"
    pte = Widget::PlainTextEdit.new parent: s, width: 20, height: 5, placeholder_text: "notes"
    te = Widget::TextEdit.new parent: s, width: 20, height: 5, placeholder_text: "body"

    le.placeholder_text.should eq "name"
    pte.placeholder_text.should eq "notes"
    te.placeholder_text.should eq "body"

    le.placeholder_visible?.should be_true
    pte.placeholder_visible?.should be_true
    te.placeholder_visible?.should be_true
  end

  it "shows the placeholder only while the buffer is empty" do
    s = headless_screen(80, 24)
    pte = Widget::PlainTextEdit.new parent: s, width: 20, height: 5, placeholder_text: "notes"
    s.repaint
    pte.content.should eq "notes"
    pte.value.should eq "" # purely visual

    pte.value = "hi"
    s.repaint
    pte.content.should eq "hi"
    pte.placeholder_visible?.should be_false
  end

  it "repaints when the placeholder itself changes on an empty editor" do
    s = headless_screen(80, 24)
    pte = Widget::PlainTextEdit.new parent: s, width: 20, height: 5, placeholder_text: "a"
    s.repaint
    pte.placeholder_text = "b"
    s.repaint
    pte.content.should eq "b"
  end

  it "paints the placeholder on a rich TextEdit too" do
    s = headless_screen(80, 24)
    Widget::TextEdit.new parent: s, top: 0, left: 0, width: 20, height: 3,
      placeholder_text: "body"
    s.repaint
    (0..3).map { |i| s.cell_rows[0][i].char }.join.should eq "body"
  end
end

describe "§2.5 validator lives on LineEdit" do
  it "reports acceptance through #acceptable_input?" do
    s = headless_screen(80, 24)
    le = Widget::LineEdit.new parent: s, width: 20, height: 1
    le.acceptable_input?.should be_true # no validator accepts anything

    le.validator = ->(v : String) { v == "good" }
    le.value = "bad"
    le.acceptable_input?.should be_false
    le.value = "good"
    le.acceptable_input?.should be_true
  end

  it "refuses to submit an unacceptable line, keeping the read (and dialog) open" do
    s = headless_screen(80, 24, default_quit_keys: true)
    d = Widget::InputDialog.new parent: s, top: 0, left: 0, width: 40, height: 8
    d.validator = ->(v : String) { v == "good" }

    got = [] of String?
    d.open("Name?") { |v| got << v }

    d.line_edit.value = "bad"
    d.line_edit.submit
    got.size.should eq 0
    d.visible?.should be_true

    d.line_edit.value = "good"
    d.line_edit.submit
    got.should eq ["good"]
  end

  it "is delegated by InputDialog to its field" do
    s = headless_screen(80, 24)
    d = Widget::InputDialog.new parent: s, top: 0, left: 0, width: 40, height: 8
    v = ->(x : String) { x.size > 2 }
    d.validator = v
    d.line_edit.validator.should eq v
  end
end

describe "§2.5 DateTimeEdit date/time accessors and bounds" do
  it "splits and rejoins the value" do
    s = headless_screen(80, 24)
    e = Widget::DateTimeEdit.new parent: s, date_time: Time.utc(2024, 5, 6, 7, 8, 9)
    e.date.should eq Time.utc(2024, 5, 6)
    e.time.should eq 7.hours + 8.minutes + 9.seconds

    e.date = Time.utc(2020, 1, 2)
    e.date_time.should eq Time.utc(2020, 1, 2, 7, 8, 9)

    e.time = 1.hour + 2.minutes
    e.date_time.should eq Time.utc(2020, 1, 2, 1, 2, 0)
  end

  it "clamps every write into [minimum_date_time, maximum_date_time]" do
    s = headless_screen(80, 24)
    e = Widget::DateTimeEdit.new parent: s, date_time: Time.utc(2024, 5, 6, 12, 0, 0)
    e.set_date_time_range Time.utc(2024, 5, 1), Time.utc(2024, 5, 10)

    e.date_time = Time.utc(2030, 1, 1)
    e.date_time.should eq Time.utc(2024, 5, 10)

    e.date_time = Time.utc(2000, 1, 1)
    e.date_time.should eq Time.utc(2024, 5, 1)
  end

  it "carries the opposite bound rather than inverting the range" do
    s = headless_screen(80, 24)
    e = Widget::DateTimeEdit.new parent: s, date_time: Time.utc(2024, 5, 6)
    e.set_date_time_range Time.utc(2024, 1, 1), Time.utc(2024, 12, 31)

    e.minimum_date_time = Time.utc(2025, 6, 1)
    e.maximum_date_time.should eq Time.utc(2025, 6, 1)
  end
end

describe "§2.5 Table cell model" do
  it "reports counts, reads and writes single cells, and exposes the header row" do
    s = headless_screen(80, 24)
    t = Widget::Table.new parent: s, rows: [
      ["Name", "Email"],
      ["Alice", "a@x"],
      ["Bob", "b@x"],
    ]

    t.row_count.should eq 3
    t.column_count.should eq 2
    t[1, 0].should eq "Alice"
    t[9, 0].nil?.should be_true
    t[1, 9].nil?.should be_true

    t[1, 0] = "Alicia"
    t[1, 0].should eq "Alicia"
    t.rows[1][0].should eq "Alicia"
    # The write went through the render rebuild, not just the array.
    t.content.includes?("Alicia").should be_true

    t.header_labels.should eq ["Name", "Email"]
    t.header_labels = ["N", "E"]
    t.header_labels.should eq ["N", "E"]
    t.row_count.should eq 3
  end

  it "keeps the same row arrays across a cell write (no wholesale copy)" do
    s = headless_screen(80, 24)
    t = Widget::Table.new parent: s, rows: [["a", "b"], ["c", "d"]]
    before = t.rows[1]
    t[1, 1] = "D"
    t.rows[1].same?(before).should be_true
  end
end

describe "§2.5 Float64 range signal" do
  it "DoubleSpinBox emits Event::DoubleRangeChanged instead of nothing" do
    s = headless_screen(80, 24)
    d = Widget::DoubleSpinBox.new parent: s, minimum: 0.0, maximum: 10.0, value: 5.0
    seen = [] of Tuple(Float64, Float64)
    d.on(Crysterm::Event::DoubleRangeChanged) { |e| seen << {e.minimum, e.maximum} }

    d.set_range 1.0, 4.0
    seen.should eq [{1.0, 4.0}]
    d.value.should eq 4.0 # still re-clamped
  end

  it "leaves the Int32 family on Event::RangeChanged" do
    s = headless_screen(80, 24)
    sb = Widget::SpinBox.new parent: s, minimum: 0, maximum: 10
    seen = [] of Tuple(Int32, Int32)
    sb.on(Crysterm::Event::RangeChanged) { |e| seen << {e.minimum, e.maximum} }
    sb.set_range 2, 5
    seen.should eq [{2, 5}]
  end
end

describe "§2.5 Mixin::ActionBar#items answers with label strings" do
  it "matches Mixin::ItemView#items' type; the Command model is #commands" do
    s = headless_screen(80, 24)
    bar = Widget::CommandBar.new parent: s, width: 40, height: 1
    bar.add_item("open") { }
    bar.add_item("quit") { }

    bar.items.should eq ["open", "quit"]
    bar.commands.map(&.text).should eq ["open", "quit"]
    bar.items = ["a", "b", "c"]
    bar.items.should eq ["a", "b", "c"]
    bar.commands.size.should eq 3
  end
end

describe "§2.6 ProgressBar is a read-only indicator by default" do
  it "takes no keys and no focus unless asked" do
    s = headless_screen(80, 24)
    pb = Widget::ProgressBar.new parent: s, width: 20, height: 1
    pb.keys?.should be_false
    pb.focus_policy.should eq Crysterm::Widget::FocusPolicy::None

    pb.value = 20
    # No KeyPress handler was installed, so the arrow key changes nothing.
    pb.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::Right)
    pb.value.should eq 20
  end

  it "keys: true restores the interactive behavior and focusability" do
    s = headless_screen(80, 24)
    pb = Widget::ProgressBar.new parent: s, width: 20, height: 1, keys: true, single_step: 5
    pb.keys?.should be_true
    pb.focus_policy.accepts_tab?.should be_true

    pb.value = 20
    pb.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::Right)
    pb.value.should eq 25
  end
end

describe "§2.7 renamed widgets" do
  it "Widget::AbstractInteractive is the interactive base (no Widget::Input)" do
    s = headless_screen(80, 24)
    w = Widget::AbstractInteractive.new parent: s, width: 10, height: 3
    w.focus_policy.accepts_tab?.should be_true
    Widget::LineEdit.new(parent: s).is_a?(Widget::AbstractInteractive).should be_true
    Widget::Button.new(parent: s).is_a?(Widget::AbstractInteractive).should be_true
  end

  it "Widget::CommandBar is the ActionBar-based strip (no ListBar)" do
    s = headless_screen(80, 24)
    bar = Widget::CommandBar.new parent: s, width: 20, height: 1
    bar.css_tag.should eq "w-commandbar"
    Widget::TabWidget.new(parent: s, width: 20, height: 6).tab_bar
      .is_a?(Widget::CommandBar).should be_true
  end

  it "the Pine record lists derive RecordList directly (no SelectableList alias)" do
    s = headless_screen(80, 24)
    Widget::Pine::FolderList.new(parent: s, width: 20, height: 5)
      .is_a?(Widget::RecordList(Widget::Pine::Folder)).should be_true
  end
end

describe "§2.7 one dialog presentation verb: #open" do
  it "MessageBox#open(text, time) is the notification form" do
    s = headless_screen(80, 24)
    m = Widget::MessageBox.new parent: s, top: 0, left: 0, width: 40, height: 5
    ran = false
    m.open("hi", nil) { ran = true }
    m.visible?.should be_true
    m.accept
    ran.should be_true
    m.result.should eq Widget::Dialog::Code::Accepted.to_i
  end

  it "MessageBox#open(text) { |yes| } is the question form" do
    s = headless_screen(80, 24, default_quit_keys: true)
    m = Widget::MessageBox.new parent: s, top: 0, left: 0, width: 40, height: 8
    answer = nil.as(Bool?)
    m.open("Sure?") { |yes| answer = yes }
    s.emit Crysterm::Event::KeyPress, 'y', nil
    answer.should be_true
    m.result.should eq Widget::Dialog::Code::Accepted.to_i
  end

  it "MessageBox#open(text, choices) { |i| } is the multi-choice form" do
    s = headless_screen(80, 24, default_quit_keys: true)
    m = Widget::MessageBox.new parent: s, top: 0, left: 0, width: 40, height: 8
    chosen = nil.as(Int32?)
    m.open("Pick", ["A", "B", "C"]) { |i| chosen = i }
    s.repaint
    bb = m.children.find(&.is_a?(Widget::DialogButtonBox)).as(Widget::DialogButtonBox)
    bb.buttons[2].click
    chosen.should eq 2
  end

  it "InputDialog#open replaces #read_input" do
    s = headless_screen(80, 24, default_quit_keys: true)
    d = Widget::InputDialog.new parent: s, top: 0, left: 0, width: 40, height: 8
    got = nil.as(String?)
    d.open("Name?") { |v| got = v }
    d.line_edit.value = "zoe"
    d.line_edit.submit
    got.should eq "zoe"
  end

  it "ColorDialog#open replaces #get_color" do
    s = headless_screen(80, 24, default_quit_keys: true)
    cd = Widget::ColorDialog.new parent: s, top: 0, left: 0, width: 56, height: 20
    calls = 0
    cd.open { |_| calls += 1 }
    cd.reject
    calls.should eq 1
  end

  it "keeps the one-call class presenters under coherent names" do
    s = headless_screen(80, 24, default_quit_keys: true)
    Widget::MessageBox.information(s, "saved").is_a?(Widget::MessageBox).should be_true
    Widget::MessageBox.ask(s, "ok?") { }.is_a?(Widget::MessageBox).should be_true
    Widget::InputDialog.read(s, "Name:") { }.is_a?(Widget::InputDialog).should be_true
  end
end

describe "§2.8 constructor polish" do
  it "ProgressBar has one state argument, `value:`; `percent` stays a property" do
    s = headless_screen(80, 24)
    pb = Widget::ProgressBar.new parent: s, width: 20, height: 1,
      minimum: 0, maximum: 200, value: 50
    pb.value.should eq 50
    pb.percent.should eq 25
    pb.percent = 50
    pb.value.should eq 100
  end

  it "ActionBar::Command hotkeys are `shortcuts:`, never `keys:`" do
    s = headless_screen(80, 24, default_quit_keys: true)
    bar = Widget::CommandBar.new parent: s, width: 40, height: 1
    fired = 0
    bar.add_item("quit", shortcuts: ["q"]) { fired += 1 }
    bar.commands.first.shortcuts.should eq ["q"]
    s.repaint
    s.emit Crysterm::Event::KeyPress, 'q', nil
    fired.should eq 1
  end

  it "scroll-bar visibility is only `scrollbar_policy:`" do
    s = headless_screen(80, 24)
    b = Widget::ScrollableBox.new parent: s, width: 10, height: 5,
      scrollbar_policy: :always_off
    b.scrollbar_policy.should eq Crysterm::Widget::ScrollBarPolicy::AlwaysOff
    b.scrollbar?.should be_false
  end
end

describe "§2.8 item objects replace the two-arg set_* pairs" do
  it "TabWidget: tabs[i].text =" do
    s = headless_screen(80, 24)
    t = Widget::TabWidget.new parent: s, width: 60, height: 20
    t.add_tab "A", Widget::Box.new
    t.add_tab "B", Widget::Box.new
    t.tabs[1].text = "Bee"
    t.tab_titles.should eq ["A", "Bee"]
    t.tab_bar.item_texts.should eq ["A", "Bee"]
  end

  it "Splitter: dividers[i].position =" do
    s = headless_screen(80, 24)
    sp = Widget::Splitter.new parent: s, top: 0, left: 0, width: 40, height: 10
    sp.add_widget Widget::Box.new
    sp.add_widget Widget::Box.new
    s.repaint
    sp.dividers[0].position = 12
    sp.dividers[0].position.should eq 12
    sp.dividers[0].index.should eq 0
  end

  it "StatusBar: add_permanent returns a Section handle" do
    s = headless_screen(80, 24)
    bar = Widget::StatusBar.new parent: s, bottom: 0, left: 0, width: 40, height: 1
    pos = bar.add_permanent "Ln 1"
    bar.add_permanent "UTF-8"
    pos.text = "Ln 4, Col 12"
    bar.permanent.should eq ["Ln 4, Col 12", "UTF-8"]
    bar.permanent_sections.map(&.text).should eq ["Ln 4, Col 12", "UTF-8"]
  end

  it "Tree: expand/collapse/toggle and Node#expanded= are the only spellings" do
    s = headless_screen(80, 24)
    t = Widget::Tree.new parent: s, width: 30, height: 10
    root = t.add "root"
    root.add "child"
    root.expanded?.should be_false
    root.expanded = true
    root.expanded?.should be_true
    t.collapse root
    root.expanded?.should be_false
    t.toggle root
    root.expanded?.should be_true
  end
end

describe "§2.8 Wizard is a Mixin::PagedContainer" do
  it "uses the shared paged vocabulary, keeping only its own verbs" do
    s = headless_screen(80, 24, default_quit_keys: true)
    w = Widget::Wizard.new parent: s, width: 50, height: 16
    p0 = Widget::Box.new content: "one"
    p1 = Widget::Box.new content: "two"
    w.add_page "One", p0
    w.add_page "Two", p1

    w.count.should eq 2
    w.pages.size.should eq 2
    w.index_of(p1).should eq 1
    w.current_widget.same?(p0).should be_true

    w.advance
    w.current_index.should eq 1
    w.back
    w.current_index.should eq 0

    # Back never wraps (the wizard-specific semantics that earn the verb).
    w.back
    w.current_index.should eq 0
  end
end

describe "§2.8 MenuBar#open_menu/#toggle_menu" do
  it "no longer collides with Dialog#open / AbstractButton#toggle" do
    s = headless_screen(80, 24)
    bar = Widget::MenuBar.new parent: s, top: 0, left: 0, width: 40, height: 1
    bar.add_menu "File"
    bar.add_menu "Edit"
    s.repaint

    bar.open_menu 1
    bar.open_index.should eq 1
    bar.toggle_menu 1
    bar.open_index.nil?.should be_true
  end
end
