require "./spec_helper"

include Crysterm

private def pls_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

private def pls_items
  ["Apricot", "Banana", "Cherry"]
end

private def press(w, key : Tput::Key)
  w.on_keypress Crysterm::Event::KeyPress.new('\0', key)
end

private def press_space(w)
  w.on_keypress Crysterm::Event::KeyPress.new(' ')
end

describe "Pine::ListSelect" do
  it "toggles a row into #checked with the space bar (multi mode)" do
    s = pls_screen
    ls = Crysterm::Widget::Pine::ListSelect(String).new pls_items,
      label: ->(x : String) { x }, multi: true, parent: s

    ls.checked.should be_empty
    press_space ls
    ls.checked.should eq ["Apricot"]
    press_space ls
    ls.checked.should be_empty
  end

  it "returns checked items from #selection (multi mode)" do
    s = pls_screen
    ls = Crysterm::Widget::Pine::ListSelect(String).new pls_items,
      label: ->(x : String) { x }, multi: true, parent: s

    press_space ls # check Apricot
    press ls, Tput::Key::Down
    press ls, Tput::Key::Down
    press_space ls # check Cherry
    ls.selection.should eq ["Apricot", "Cherry"]
  end

  it "runs on_confirm with the selection on #confirm (multi mode)" do
    s = pls_screen
    confirmed = [] of String
    ls = Crysterm::Widget::Pine::ListSelect(String).new pls_items,
      label: ->(x : String) { x }, multi: true, parent: s,
      on_confirm: ->(chosen : Array(String)) { confirmed = chosen; nil }

    press_space ls # check Apricot
    # In multi mode `activate` toggles (it does not confirm); `confirm` applies.
    ls.confirm
    confirmed.should eq ["Apricot"]
  end

  it "returns the highlighted item from #selection (single mode)" do
    s = pls_screen
    ls = Crysterm::Widget::Pine::ListSelect(String).new pls_items,
      label: ->(x : String) { x }, multi: false, parent: s

    press ls, Tput::Key::Down
    ls.selection.should eq ["Banana"]
    ls.checked.should be_empty
  end

  it "select_all / clear_selection affect #checked (multi mode)" do
    s = pls_screen
    ls = Crysterm::Widget::Pine::ListSelect(String).new pls_items,
      label: ->(x : String) { x }, multi: true, parent: s

    ls.select_all
    ls.checked.should eq pls_items
    ls.clear_selection
    ls.checked.should be_empty
  end

  it "preselects items via #set_checked (multi mode), ignoring unknown items" do
    s = pls_screen
    ls = Crysterm::Widget::Pine::ListSelect(String).new pls_items,
      label: ->(x : String) { x }, multi: true, parent: s

    ls.set_checked ["Banana", "Cherry", "Durian"] # Durian is not in the list
    ls.checked.should eq ["Banana", "Cherry"]
  end

  # In multi mode, activation (a click, via activate_on_click) TOGGLES the row
  # rather than confirming — so clicking a row checks/unchecks it without
  # dismissing. `#confirm` is the explicit apply.
  it "toggles (not confirms) on activate in multi mode; #confirm applies" do
    s = pls_screen
    confirmed = nil.as(Array(String)?)
    ls = Crysterm::Widget::Pine::ListSelect(String).new pls_items,
      label: ->(x : String) { x }, multi: true, parent: s,
      on_confirm: ->(sel : Array(String)) { confirmed = sel; nil }

    ls.activate_on_click?.should be_true
    ls.selekt 1
    ls.activate
    ls.checked.should eq ["Banana"]
    confirmed.should be_nil # toggling did not confirm
    ls.activate
    ls.checked.should be_empty

    ls.set_checked ["Apricot", "Cherry"]
    ls.confirm
    confirmed.should eq ["Apricot", "Cherry"]
  end
end
