require "./spec_helper"

include Crysterm

private def b17_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# B17-20: `ItemView#items=` used to start with an unconditional
# `self.current_index = 0`, which on a *rendered* list with a non-zero selection
# took the full setter path — scrolling to the top and emitting an
# `ItemSelected` carrying the OLD row-0 item — before the real selection was
# restored (a second emission). A wholesale `items=` therefore fired listeners
# twice per assignment, the first spuriously. The reset is now quiet, so exactly
# one `ItemSelected` fires, at the restored index.
describe "ItemView#items= single ItemSelected emission" do
  it "emits exactly one ItemSelected (at the restored index) on unchanged items" do
    s = b17_screen
    list = Crysterm::Widget::List.new parent: s, items: ["a", "b", "c"]
    s.repaint # lay out so `@lpos` is set and `current_index=` reaches the emit
    list.current_index = 2
    list.current_text.should eq "c"

    indices = [] of Int32
    list.on(Crysterm::Event::ItemSelected) { |e| indices << e.index }

    # Same size, same texts: selection is preserved by the restore branch.
    list.items = ["a", "b", "c"]

    # Exactly one emission, and it is the restored row (2) — never the transient
    # spurious row 0 the old code emitted first.
    indices.should eq [2]
    list.current_index.should eq 2
    list.current_text.should eq "c"
  end
end

private def b17_menu(s)
  m = Crysterm::Widget::Menu.new parent: s
  m.add_action("New") { }
  export = m.add_submenu "Export", [Crysterm::Action.new("pdf"), Crysterm::Action.new("html")]
  status = m.add_action "Sync: idle"
  {m, export, status}
end

private def b17_open_sub(s, m)
  m.popup 6, 2
  s.repaint
  m.current_index = 1 # the "Export" submenu row (row > 0)
  m.hover_item 1      # opens the submenu
  s.repaint
  m.@submenu_open.not_nil!
end

# B17-16: while a submenu is open, ANY row rebuild (an external action change, an
# add/remove) went through `sync_items -> items=`, whose transient index churn
# dispatched into `Menu#current_index=` and force-closed the submenu the user was
# navigating. The rebuild is now guarded (`@syncing_items`) and reconciled once at
# the end of `sync_items`: keep the submenu open (re-anchoring it) when its action
# survives, close it only when the action was removed/hidden.
describe "Menu submenu survives unrelated row rebuilds" do
  it "leaves an open submenu open when an unrelated action's label changes" do
    s = b17_screen
    m, _export, status = b17_menu s
    b17_open_sub s, m
    m.@submenu_open.should_not be_nil

    # An external label update on a *different* action triggers refresh_rows ->
    # sync_items. The open submenu must not be torn down.
    status.text = "Sync: running"

    m.@submenu_open.should_not be_nil
  end

  it "leaves an open submenu open when the submenu action's own label changes" do
    s = b17_screen
    m, export, _status = b17_menu s
    b17_open_sub s, m
    m.@submenu_open.should_not be_nil

    export.text = "Export as..."

    m.@submenu_open.should_not be_nil
  end

  it "closes the submenu when its own action is removed" do
    s = b17_screen
    m, export, _status = b17_menu s
    b17_open_sub s, m
    m.@submenu_open.should_not be_nil

    # The action backing the open submenu is gone: it can no longer be anchored,
    # so the submenu is closed by the post-sync reconcile.
    m.remove_action export

    m.@submenu_open.should be_nil
  end

  it "closes the submenu when its own action is hidden" do
    s = b17_screen
    m, export, _status = b17_menu s
    b17_open_sub s, m
    m.@submenu_open.should_not be_nil

    export.visible = false # drops it from @visible_actions

    m.@submenu_open.should be_nil
  end
end
