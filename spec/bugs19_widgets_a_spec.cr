require "./spec_helper"

include Crysterm

# Regression specs for BUGS19 #30, #31, #32.
#
#  #30 (src/widget/splitter.cr `#add_widget`/`#insert_widget`/`#remove`):
#     re-adding a pane the splitter already held pushed a duplicate entry
#     onto `@panes` before `#append` detached the original — whose own
#     `#remove` callback then deleted *both* (equal, by-value) entries from
#     `@panes`, leaving the widget attached as a plain child but absent from
#     the pane list. `#add_widget`/`#insert_widget` now dedupe an existing
#     pane (as a move) before touching `@panes`; `#remove` deletes by index.
#
#  #31 (src/mixin/item_view/model.cr `#remove_item`/`#insert_item`): the
#     cursor realignment after a row mutation routed entirely through
#     `#current_index=`, which no-ops while `interactive?` is false or
#     `#selection_mode` is `NoSelection` — leaving the raw `@selected` stale
#     (out of `@item_boxes` bounds) on such a view, so a later Enter/Escape
#     raised `IndexError`. The raw index is now realigned unconditionally,
#     and `#activate_current`/`#cancel_current` carry a defensive bounds
#     check besides.
#
#  #32 (src/widget/tool_bar.cr): removing a button via `#remove_item` (or a
#     wholesale `#items=`/`#clear`) left its backing `Action`'s window
#     accelerator installed and its change-watcher alive — the dead action
#     kept firing on its old shortcut. `ToolBar` now overrides both to
#     uninstall the shortcut, unwatch the action, and drop the
#     `@item_actions` entry, mirroring `Menu#remove_action`/`#clear`.

describe "Splitter#add_widget/#insert_widget re-add (BUGS19 #30)" do
  it "moves an existing pane to the end instead of dropping it from @panes" do
    s = headless_screen(80, 24)
    sp = Crysterm::Widget::Splitter.new parent: s, width: 40, height: 10
    a = Crysterm::Widget::Box.new
    b = Crysterm::Widget::Box.new
    c = Crysterm::Widget::Box.new
    sp << a << b << c
    sp.count.should eq 3

    sp.add_widget a

    sp.count.should eq 3
    sp.panes.should eq [b, c, a]
    sp.panes.count(&.same?(a)).should eq 1
    sp.children.count(&.same?(a)).should eq 1
    sp.dividers.size.should eq 2
    sp.sizes.size.should eq 3
  end

  it "moves an existing pane to a mid-list index via insert_widget" do
    s = headless_screen(80, 24)
    sp = Crysterm::Widget::Splitter.new parent: s, width: 40, height: 10
    a = Crysterm::Widget::Box.new
    b = Crysterm::Widget::Box.new
    c = Crysterm::Widget::Box.new
    sp << a << b << c

    sp.insert_widget 0, c

    sp.count.should eq 3
    sp.panes.should eq [c, a, b]
    sp.panes.count(&.same?(c)).should eq 1
    sp.children.count(&.same?(c)).should eq 1
    sp.dividers.size.should eq 2
  end

  it "readding the same pane repeatedly never desyncs @panes from the children" do
    s = headless_screen(80, 24)
    sp = Crysterm::Widget::Splitter.new parent: s, width: 40, height: 10
    a = Crysterm::Widget::Box.new
    b = Crysterm::Widget::Box.new
    sp << a << b

    3.times { sp.add_widget a }

    sp.count.should eq 2
    sp.panes.should eq [b, a]
    sp.panes.count(&.same?(a)).should eq 1
    sp.children.count(&.same?(a)).should eq 1
    sp.dividers.size.should eq 1
    sp.sizes.size.should eq 2
  end
end

describe "ItemView non-interactive @selected realignment (BUGS19 #31)" do
  it "keeps @selected in bounds when a non-interactive view's selected row is removed, so Enter is safe" do
    s = headless_screen(80, 24)
    list = Crysterm::Widget::List.new parent: s, items: ["a", "b", "c"]
    list.current_index = 2
    list.interactive = false

    list.remove_item 2

    activated = [] of Int32
    list.on(Crysterm::Event::ItemActivated) { |e| activated << e.index }
    list.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::Enter)

    activated.should eq [1]
  end

  it "keeps @selected in bounds through insert_item on a NoSelection view, so Escape is safe" do
    s = headless_screen(80, 24)
    list = Crysterm::Widget::List.new parent: s, items: ["a", "b"]
    list.current_index = 1
    list.selection_mode = :no_selection

    list.insert_item 0, "z" # shifts the stale-but-realigned cursor to 2

    cancelled = [] of Int32
    list.on(Crysterm::Event::ItemCancelled) { |e| cancelled << e.index }
    list.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::Escape)

    cancelled.should eq [2]
  end
end

describe "ToolBar#remove_item action teardown (BUGS19 #32)" do
  it "uninstalls the shortcut, stops watching, and drops the @item_actions entry" do
    s = headless_screen(80, 24)
    tb = Crysterm::Widget::ToolBar.new parent: s, top: 0, left: 0, width: "100%", height: 1
    bold = Crysterm::Action.new "Bold", shortcut: Tput::Key::CtrlB
    fired = 0
    bold.on_triggered { fired += 1 }
    tb.add_action bold

    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlB)
    fired.should eq 1

    tb.remove_item(0)

    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlB)
    fired.should eq 1 # the old accelerator no longer fires
  end

  it "clear (routed through the wholesale items= rebuild) also uninstalls every accelerator" do
    s = headless_screen(80, 24)
    tb = Crysterm::Widget::ToolBar.new parent: s, top: 0, left: 0, width: "100%", height: 1
    bold = Crysterm::Action.new "Bold", shortcut: Tput::Key::CtrlB
    fired = 0
    bold.on_triggered { fired += 1 }
    tb.add_action bold

    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlB)
    fired.should eq 1

    tb.clear

    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlB)
    fired.should eq 1 # unchanged: the accelerator no longer fires post-clear
  end
end
