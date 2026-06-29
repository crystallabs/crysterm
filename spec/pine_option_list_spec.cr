require "./spec_helper"

include Crysterm

private def pol_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

private def pol_options
  [
    Crysterm::Widget::Pine::OptionList::Option.new("line-wrap",
      Crysterm::Widget::Pine::OptionKind::Toggle,
      "Wrap long lines", value: "true"),
    Crysterm::Widget::Pine::OptionList::Option.new("signature",
      Crysterm::Widget::Pine::OptionKind::Text,
      "Signature", value: "hi"),
    Crysterm::Widget::Pine::OptionList::Option.new("tab-width",
      Crysterm::Widget::Pine::OptionKind::Number,
      "Spaces per tab", value: "4"),
    Crysterm::Widget::Pine::OptionList::Option.new("theme",
      Crysterm::Widget::Pine::OptionKind::Choice,
      "Color theme", value: "dark", allowed: %w[dark light solarized]),
  ]
end

private def press(w, char : Char = '\0', key : Tput::Key? = nil)
  w.on_keypress Crysterm::Event::KeyPress.new(char, key)
end

describe "Pine::OptionList" do
  it "toggles a Toggle option and fires the callback" do
    s = pol_screen
    fired = [] of String
    opts = pol_options
    opts[0].callback = ->(v : String) { fired << v; nil }
    ol = Crysterm::Widget::Pine::OptionList.new opts, parent: s

    ol.selekt 0
    ol.records[0].on?.should be_true
    ol.activate # Enter
    ol.records[0].on?.should be_false
    fired.should eq ["false"]

    # Space also toggles.
    press ol, ' '
    ol.records[0].on?.should be_true
    fired.should eq ["false", "true"]
  end

  it "advances a Choice option through its allowed values, wrapping" do
    s = pol_screen
    ol = Crysterm::Widget::Pine::OptionList.new pol_options, parent: s

    ol.selekt 3
    ol.value("theme").should eq "dark"
    ol.activate
    ol.value("theme").should eq "light"
    ol.activate
    ol.value("theme").should eq "solarized"
    ol.activate # wraps back to the first
    ol.value("theme").should eq "dark"
  end

  it "edits a Text option inline and commits on Enter" do
    s = pol_screen
    fired = [] of String
    opts = pol_options
    opts[1].callback = ->(v : String) { fired << v; nil }
    ol = Crysterm::Widget::Pine::OptionList.new opts, parent: s

    ol.selekt 1
    ol.activate # begin editing ("hi")
    ol.editing?.should be_true
    press ol, 'X'
    press ol, key: Tput::Key::Enter # commit
    ol.editing?.should be_false
    ol.value("signature").should eq "hiX"
    fired.should eq ["hiX"]
  end

  it "rejects non-digits while editing a Number and cancels on Esc" do
    s = pol_screen
    ol = Crysterm::Widget::Pine::OptionList.new pol_options, parent: s

    ol.selekt 2
    ol.activate                      # begin editing ("4")
    press ol, 'a'                    # rejected
    press ol, '2'                    # accepted
    press ol, key: Tput::Key::Escape # cancel, discard
    ol.editing?.should be_false
    ol.value("tab-width").should eq "4"
    ol.records[2].to_i.should eq 4
  end

  # A mouse click selects the clicked row *before* it activates it. An edit in
  # progress must therefore commit to the row where it began (not the row just
  # clicked), or the typed value leaks into the wrong option.
  it "commits an in-progress edit to its own row when another row is activated" do
    s = pol_screen
    ol = Crysterm::Widget::Pine::OptionList.new pol_options, parent: s

    ol.selekt 1
    ol.activate   # begin editing row 1 ("hi")
    press ol, 'X' # buffer -> "hiX"

    # Simulate a click on row 3 (theme): the selection moves first, then the
    # click activates.
    ol.selekt 3
    ol.activate

    ol.editing?.should be_false
    ol.value("signature").should eq "hiX" # committed to the edited row
    ol.value("theme").should eq "dark"    # the clicked row is untouched
  end

  it "#value returns the current value and nil for unknown names" do
    s = pol_screen
    ol = Crysterm::Widget::Pine::OptionList.new pol_options, parent: s

    ol.value("line-wrap").should eq "true"
    ol.value("nope").should be_nil
  end
end
