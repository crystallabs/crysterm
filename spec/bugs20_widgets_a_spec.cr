require "./spec_helper"

describe "Menu separator rows" do
  it "drop the item class when a reused row box becomes a separator" do
    s = headless_screen(40, 12)
    menu = Crysterm::Widget::Menu.new parent: s
    a = menu.add_action "A"
    menu.add_separator
    menu.add_action "B"

    # Hiding the first action shifts the separator onto the box "A" used.
    a.visible = false

    menu.item_boxes.size.should eq 2
    menu.item_boxes[0].css_classes.includes?("Item").should be_false
    menu.item_boxes[1].css_classes.includes?("Item").should be_true
  end
end

describe "MenuBar menu bookkeeping" do
  it "withdraws the accelerator of an action removed from a menu" do
    s = headless_screen(80, 24)
    bar = Crysterm::Widget::MenuBar.new parent: s, top: 0, left: 0, width: "100%", height: 1
    copy = Crysterm::Action.new "Copy", shortcut: ::Tput::Key::CtrlC
    fired = 0
    copy.on(Crysterm::Event::Triggered) { fired += 1 }
    edit = bar.add_menu "Edit", [copy]

    edit.remove_action copy
    s.emit Crysterm::Event::KeyPress.new('\0', ::Tput::Key::CtrlC)
    fired.should eq 0
  end

  it "keeps the accelerator of an action another menu of the bar still holds" do
    s = headless_screen(80, 24)
    bar = Crysterm::Widget::MenuBar.new parent: s, top: 0, left: 0, width: "100%", height: 1
    copy = Crysterm::Action.new "Copy", shortcut: ::Tput::Key::CtrlC
    fired = 0
    copy.on(Crysterm::Event::Triggered) { fired += 1 }
    edit = bar.add_menu "Edit", [copy]
    bar.add_menu "Other", [copy]

    edit.remove_action copy
    s.emit Crysterm::Event::KeyPress.new('\0', ::Tput::Key::CtrlC)
    fired.should eq 1
  end

  it "drops a title's menu and mnemonic together with the title" do
    s = headless_screen(80, 24)
    bar = Crysterm::Widget::MenuBar.new parent: s, top: 0, left: 0, width: "100%", height: 1
    bar.add_menu "&File"
    edit = bar.add_menu "&Edit"

    bar.remove_item 0
    bar.menus.size.should eq 1
    bar.menus[0].same?(edit).should be_true
    bar.mnemonics.should eq ['e']

    bar.clear
    bar.menus.empty?.should be_true
    bar.mnemonics.empty?.should be_true
  end
end

describe "ComboBox editable free text" do
  it "survives removing or appending other options" do
    s = headless_screen(80, 24)
    cb = Crysterm::Widget::ComboBox.new parent: s, top: 0, left: 0, width: 12, height: 1,
      options: ["a", "b", "c"], editable: true
    cb.current_text = "zzz"
    cb.current_text.should eq "zzz"

    cb.remove_item 2
    cb.current_text.should eq "zzz"

    cb.add_items ["d"]
    cb.current_text.should eq "zzz"
  end
end

describe "Paged containers re-adding a page they hold" do
  it "TabWidget#add_tab moves the page instead of raising" do
    s = headless_screen(40, 12)
    tabs = Crysterm::Widget::TabWidget.new parent: s, width: 30, height: 8
    a = Crysterm::Widget::Box.new
    b = Crysterm::Widget::Box.new
    tabs.add_tab "A", a
    tabs.add_tab "B", b

    tabs.add_tab "A2", a
    tabs.pages.size.should eq 2
    tabs.tab_titles.should eq ["B", "A2"]
    tabs.tab_bar.commands.size.should eq 2
  end

  it "StackedWidget#add_widget of the current page leaves a visible current page" do
    s = headless_screen(40, 12)
    stack = Crysterm::Widget::StackedWidget.new parent: s, width: 20, height: 5
    a = Crysterm::Widget::Box.new
    b = Crysterm::Widget::Box.new
    stack.add_widget a
    stack.add_widget b

    stack.add_widget a
    stack.pages.size.should eq 2
    cur = stack.current_widget
    cur.nil?.should be_false
    cur.try(&.visible?).should be_true
  end

  it "ToolBox#add_item wires the re-added section's header to its new index" do
    s = headless_screen(40, 16)
    tb = Crysterm::Widget::ToolBox.new parent: s, width: 20, height: 10
    a = Crysterm::Widget::Box.new
    b = Crysterm::Widget::Box.new
    tb.add_item "A", a
    tb.add_item "B", b

    tb.add_item "A2", a
    tb.sections.size.should eq 2
    tb.sections[1].header.emit Crysterm::Event::Click
    tb.current_index.should eq 1
  end
end

describe "MainWindow slots" do
  it "forget a bar destroyed behind the main window's back" do
    s = headless_screen(80, 24)
    mw = Crysterm::Widget::MainWindow.new parent: s
    mw.menu_bar.destroy
    mw.menu_bar?.nil?.should be_true
  end

  it "let a dock detached directly be added again" do
    s = headless_screen(80, 24)
    mw = Crysterm::Widget::MainWindow.new parent: s
    dock = Crysterm::Widget::DockWidget.new title: "D"
    mw.add_dock dock
    dock.detach_from_tree
    mw.docks.empty?.should be_true

    mw.add_dock dock
    mw.docks.size.should eq 1
    dock.parent.try(&.same?(mw)).should be_true
  end
end

describe "Dialog modality and exec" do
  it "takes the modal grab again when reopened after a detach" do
    s = headless_screen(80, 24)
    dlg = Crysterm::Widget::Wizard.new parent: s, width: 30, height: 8
    dlg.open
    s.popup_grab_active?.should be_true

    dlg.detach_from_tree
    s.popup_grab_active?.should be_false

    s.append dlg
    dlg.open
    s.popup_grab_active?.should be_true
  end

  it "returns from exec as rejected when the dialog is destroyed" do
    s = headless_screen(80, 24)
    dlg = Crysterm::Widget::Wizard.new parent: s, width: 30, height: 8
    ch = Channel(Int32).new 1
    spawn { ch.send dlg.exec }
    wait_until { dlg.modal? }

    dlg.destroy
    select
    when r = ch.receive
      r.should eq 0
    when timeout(2.seconds)
      fail "exec never returned"
    end
  end
end

describe "MessageBox presentations" do
  it "a question replacing an untimed notification gets the next key" do
    s = headless_screen(80, 24)
    mb = Crysterm::Widget::MessageBox.new parent: s, width: 40, height: 8
    mb.open "hello", nil
    answers = [] of Bool
    mb.open("Sure?") { |yes| answers << yes }

    s.emit Crysterm::Event::KeyPress.new('y')
    answers.should eq [true]
  end
end

describe "GroupBox re-check" do
  it "leaves a child the application disabled disabled" do
    s = headless_screen(80, 24)
    gb = Crysterm::Widget::GroupBox.new parent: s, title: "G", checkable: true, width: 30, height: 8
    a = Crysterm::Widget::Box.new parent: gb, width: 10, height: 1
    b = Crysterm::Widget::Box.new parent: gb, top: 1, width: 10, height: 1
    b.enabled = false

    gb.checked = false
    a.disabled?.should be_true
    b.disabled?.should be_true

    gb.checked = true
    a.disabled?.should be_false
    b.disabled?.should be_true
  end
end

describe "DialogButtonBox" do
  it "closes the row up when a button is destroyed directly" do
    s = headless_screen(80, 24)
    ok = Crysterm::Widget::DialogButtonBox::StandardButton::Ok
    cancel = Crysterm::Widget::DialogButtonBox::StandardButton::Cancel
    bb = Crysterm::Widget::DialogButtonBox.new parent: s, buttons: ok | cancel

    bb.button(ok).try &.destroy
    bb.buttons.size.should eq 1
    bb.button(ok).nil?.should be_true
    bb.standard_buttons.should eq cancel
  end
end
