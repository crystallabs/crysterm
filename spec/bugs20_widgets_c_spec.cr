require "./spec_helper"

private alias Transcript = Crysterm::Widget::Chat::Transcript
private alias ChatGlyphs = Crysterm::Chat::Glyphs
private alias TaskState = Crysterm::Chat::Task::State

describe "Chat::Transcript fold markers" do
  it "updates the folding ancestor's marker when a hidden descendant is toggled" do
    s = headless_screen(60, 30)
    t = Transcript.new parent: s, top: 0, left: 0, width: 50, height: 25

    parent = t.append :tool_call, "parent"
    body = (1..15).map { |i| "row #{i}" }.join('\n')
    t.append :tool_result, body, parent: parent

    # Fold the parent: the child shows 10 rows + its own marker = 11 lines.
    t.toggle_collapse(0).should be_true
    t.lines.join('\n').should contain "+11 lines"

    # Expanding the folded-away child grows what the parent's marker hides.
    t.toggle_collapse(1).should be_false
    all = t.lines.join('\n')
    all.should contain "+15 lines"
    all.should_not contain "+11 lines"
  end

  it "set_class_color recolors existing entries and keeps later splices aligned" do
    s = headless_screen(60, 30)
    t = Transcript.new parent: s, top: 0, left: 0, width: 50, height: 25

    t.append :error, "boom"
    t.append :prose, "hello"
    t.set_class_color ChatGlyphs::CLASS_ERROR, "blue"
    t.content.should contain "{blue-fg}"

    body = (1..15).map { |i| "row #{i}" }.join('\n')
    t.append :tool_result, body
    t.lines.join('\n').should_not contain "row 15"
    t.toggle_collapse(2).should be_false
    all = t.lines.join('\n')
    all.should contain "row 15"
    all.should contain "boom"
    all.should contain "hello"
  end
end

describe "Chat::TaskStrip animation lifecycle" do
  it "does not resume the spinner on show after every task finished while hidden" do
    s = headless_screen(80, 24)
    reg = Crysterm::Chat::TaskRegistry.new
    strip = Crysterm::Widget::Chat::TaskStrip.new reg,
      parent: s, top: 0, left: 0, width: 60, height: 6, animate: true

    task = reg.add "job", state: TaskState::Running
    strip.running?.should be_true

    strip.hide
    strip.running?.should be_false

    reg.transition task, TaskState::Ok
    strip.show
    strip.running?.should be_false

    strip.destroy
  end
end

describe "Chat::StatusLine busy state" do
  it "stays busy while the status line is hidden" do
    s = headless_screen(80, 10)
    sl = Crysterm::Widget::Chat::StatusLine.new parent: s, bottom: 0, left: 0, width: "100%", height: 1

    sl.busy "Working"
    sl.busy?.should be_true

    sl.hide
    sl.busy?.should be_true

    sl.show
    sl.busy?.should be_true

    sl.idle
    sl.busy?.should be_false
  end
end

describe "Log max_lines" do
  it "holds the cap when one add carries many lines" do
    s = headless_screen(60, 20)
    log = Crysterm::Widget::Log.new parent: s, top: 0, left: 0, width: 50, height: 10, max_lines: 10

    burst = (1..30).map { |i| "line #{i}" }.join('\n')
    log.add burst
    log.lines.size.should be <= 10
    log.lines.last.should eq "line 30"

    log.add "tail"
    log.lines.size.should be <= 10
    log.lines.last.should eq "tail"
  end
end

describe "Pine::ListSelect" do
  it "clears the checked set when the items are replaced via records=" do
    s = headless_screen(60, 20)
    picker = Crysterm::Widget::Pine::ListSelect(String).new(
      ["a", "b", "c"],
      label: ->(x : String) { x },
      multi: true,
      parent: s, top: 0, left: 0, width: 40, height: 6)

    picker.select_all
    picker.checked.should eq ["a", "b", "c"]

    picker.records = ["x", "y"]
    picker.checked.empty?.should be_true
  end
end

describe "Pine::OptionList" do
  it "drops an in-progress edit when the options are replaced" do
    s = headless_screen(80, 20)
    opt = Crysterm::Widget::Pine::OptionListOption.new("name",
      Crysterm::Widget::Pine::OptionKind::Text, value: "old")
    ol = Crysterm::Widget::Pine::OptionList.new([opt],
      parent: s, top: 0, left: 0, width: 70, height: 6)

    ol.begin_edit
    ol.editing?.should be_true

    fresh = Crysterm::Widget::Pine::OptionListOption.new("other",
      Crysterm::Widget::Pine::OptionKind::Text, value: "keep")
    ol.options = [fresh]
    ol.editing?.should be_false

    ol.commit_edit
    ol.options[0].value.should eq "keep"
  end
end
