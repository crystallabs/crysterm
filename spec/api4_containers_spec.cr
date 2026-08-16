require "./spec_helper"

include Crysterm

# Coverage for the API4 container/menu additive conveniences:
# Menu/ToolBar `add_action`/`add_actions` symmetry (A4-35/A4-38a/A4-45),
# `Mixin::PagedContainer#widget`/`#index_of` (A4-36), `Wizard#count` (A4-40),
# `DialogButtonBox#add_button(StandardButton)`/`#remove_button` (A4-41),
# `ActionGroup#add_action(text)` (A4-42), `Menu#insert_separator`/
# `#insert_submenu` (A4-43), and `MainWindow#add_dock_widget`/
# `#remove_dock_widget` (A4-44).
describe "API4 container/menu additions" do
  describe "Widget::Menu" do
    it "#add_action(Action) appends an existing action and it fires (A4-35)" do
      win = headless_screen(40, 20, default_quit_keys: true)
      menu = Widget::Menu.new parent: win
      action = Action.new "Save"
      fired = false
      action.on(Crysterm::Event::Triggered) { fired = true }

      menu.add_action(action).should be action
      menu.actions.should contain action

      menu.activate_item 0
      fired.should be_true
    end

    it "#add_actions bulk-appends without clearing (distinct from #actions=) (A4-45)" do
      win = headless_screen(40, 20, default_quit_keys: true)
      menu = Widget::Menu.new parent: win
      first = Action.new "First"
      menu << first

      more = [Action.new("Second"), Action.new("Third")]
      menu.add_actions(more).should be menu
      menu.actions.should eq [first, more[0], more[1]]
    end

    it "#insert_separator inserts a separator action at the given index (A4-43)" do
      win = headless_screen(40, 20, default_quit_keys: true)
      menu = Widget::Menu.new parent: win
      a = Action.new "A"
      b = Action.new "B"
      menu << a
      menu << b

      sep = menu.insert_separator(1)
      sep.separator?.should be_true
      menu.actions.should eq [a, sep, b]
    end

    it "#insert_submenu inserts a submenu action at the given index (A4-43)" do
      win = headless_screen(40, 20, default_quit_keys: true)
      menu = Widget::Menu.new parent: win
      a = Action.new "A"
      b = Action.new "B"
      menu << a
      menu << b

      sub_actions = [Action.new("Sub1")]
      submenu = menu.insert_submenu(1, "More", sub_actions)
      submenu.menu?.should be_true
      submenu.menu.should eq sub_actions
      menu.actions.should eq [a, submenu, b]
    end
  end

  describe "Widget::ToolBar" do
    it "#add_action(text, &block) creates and fires an action, returning its box (A4-35)" do
      win = headless_screen(40, 20, default_quit_keys: true)
      tb = Widget::ToolBar.new parent: win, top: 0, left: 0, width: "100%", height: 1
      fired = false

      box = tb.add_action("New") { fired = true }
      box.should be_a Widget::Box

      tb.activate_item 0
      fired.should be_true
    end

    it "#add_actions loops #add_action for every action (A4-38a / A4-45)" do
      win = headless_screen(40, 20, default_quit_keys: true)
      tb = Widget::ToolBar.new parent: win, top: 0, left: 0, width: "100%", height: 1
      actions = [Action.new("One"), Action.new("Two")]
      fired = [] of String

      actions.each { |a| a.on(Crysterm::Event::Triggered) { fired << a.text } }
      tb.add_actions(actions).should be tb

      tb.activate_item 0
      tb.activate_item 1
      fired.should eq ["One", "Two"]
    end
  end

  describe "Mixin::PagedContainer (via TabWidget) (A4-36)" do
    it "#widget(index) and #index_of(widget) read through the page bookkeeping" do
      win = headless_screen(40, 20, default_quit_keys: true)
      tabs = Widget::TabWidget.new parent: win, top: 0, left: 0, width: 30, height: 10
      p0 = Widget::Box.new content: "zero"
      p1 = Widget::Box.new content: "one"
      tabs.add_tab "Zero", p0
      tabs.add_tab "One", p1

      tabs.widget(0).should eq p0
      tabs.widget(1).should eq p1
      tabs.widget(2).should be_nil

      tabs.index_of(p0).should eq 0
      tabs.index_of(p1).should eq 1
      tabs.index_of(Widget::Box.new).should be_nil
    end
  end

  describe "Widget::Wizard#count (A4-40)" do
    it "counts pages through Mixin::PagedContainer" do
      win = headless_screen(40, 20, default_quit_keys: true)
      wiz = Widget::Wizard.new parent: win, width: 50, height: 16
      wiz.count.should eq 0
      wiz.pages.size.should eq 0

      wiz.add_page "Intro", Widget::Box.new(content: "Welcome")
      wiz.add_page "Details", Widget::Box.new(content: "Info")
      wiz.count.should eq 2
      wiz.pages.size.should eq 2
      wiz.current_index.should eq 0
    end
  end

  describe "Widget::DialogButtonBox (A4-41)" do
    it "#add_button(StandardButton) keeps @standard/DISPLAY_ORDER coherent" do
      win = headless_screen(40, 20, default_quit_keys: true)
      bb = Widget::DialogButtonBox.new(parent: win, buttons: Widget::DialogButtonBox::StandardButton::Cancel)

      ok = bb.add_button Widget::DialogButtonBox::StandardButton::Ok
      ok.should be_a Widget::Button
      bb.standard_button(ok).should eq Widget::DialogButtonBox::StandardButton::Ok
      bb.standard_buttons.includes?(Widget::DialogButtonBox::StandardButton::Ok).should be_true

      # DISPLAY_ORDER puts Ok before Cancel, even though Cancel was added first.
      bb.buttons.map { |b| bb.standard_button(b) }.should eq [
        Widget::DialogButtonBox::StandardButton::Ok,
        Widget::DialogButtonBox::StandardButton::Cancel,
      ]

      # Re-adding an already-present standard button is a no-op that returns
      # the same button.
      bb.add_button(Widget::DialogButtonBox::StandardButton::Ok).should be ok
    end

    it "#remove_button detaches a button and keeps @standard coherent" do
      win = headless_screen(40, 20, default_quit_keys: true)
      bb = Widget::DialogButtonBox.new(parent: win,
        buttons: Widget::DialogButtonBox::StandardButton::Ok | Widget::DialogButtonBox::StandardButton::Cancel)
      ok = bb.button(Widget::DialogButtonBox::StandardButton::Ok).not_nil!

      bb.remove_button ok
      bb.buttons.should_not contain ok
      bb.standard_button(ok).should be_nil
      bb.standard_buttons.includes?(Widget::DialogButtonBox::StandardButton::Ok).should be_false
      bb.standard_buttons.includes?(Widget::DialogButtonBox::StandardButton::Cancel).should be_true

      # A button the box doesn't hold is a no-op.
      bb.remove_button ok
      bb.buttons.size.should eq 1
    end
  end

  describe "ActionGroup#add_action(text) (A4-42)" do
    it "builds a checkable, grouped member in one call" do
      group = ActionGroup.new
      a = group.add_action "Icons"
      a.should be_a Action
      a.checkable?.should be_true
      a.group.should be group
      group.actions.should contain a
    end

    it "is exclusive by default: checking one unchecks the other" do
      group = ActionGroup.new
      a = group.add_action "Icons"
      b = group.add_action "List"
      a.checked = true
      b.checked?.should be_false
    end
  end

  describe "Widget::MainWindow dock aliases (A4-44)" do
    it "#add_dock_widget/#remove_dock_widget alias #add_dock/#remove_dock" do
      win = headless_screen(40, 20, default_quit_keys: true)
      main = Widget::MainWindow.new parent: win, top: 0, left: 0, width: 40, height: 20
      dock = Widget::DockWidget.new title: "Files"

      main.add_dock_widget(Widget::DockWidget::Area::Left, dock).should be dock
      main.docks.should contain dock
      dock.area.should eq Widget::DockWidget::Area::Left

      main.remove_dock_widget dock
      main.docks.should_not contain dock

      # The area-less overload keeps the dock's own #area.
      dock.area = Widget::DockWidget::Area::Right
      main.add_dock_widget(dock).should be dock
      dock.area.should eq Widget::DockWidget::Area::Right
    end
  end
end
