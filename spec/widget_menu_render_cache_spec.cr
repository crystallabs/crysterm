require "./spec_helper"

include Crysterm

# Regression spec for ALLOCS.md Group J (menu per-frame allocation caches).
#
# A menu's `#render` runs `#fit_width`/`#fit_height`/`#size_rows` and re-docks
# its separators every frame. Group J made the derived data cached instead of
# rebuilt per frame:
#   J1 — separator dock-row indices reuse `@dock_rows_buf`.
#   J2 — `@visible_actions` / `@row_lefts` / `@row_rights` rebuilt only in
#        `#sync_items`; `#size_rows` early-returns on an unchanged width.
#   J4 — `#fit_width`/`#fit_height` read the cached visible-actions array.
#   J5 — `#item_on_surface` caches the surfaced style per source style.
#   J6 — `#separator_render_style` caches the derived line style.
#
# These specs render a menu (separators + multiple actions) twice and assert
# (a) the content is laid out correctly and (b) the cached arrays/styles are the
# *same objects* on the second render, i.e. nothing was rebuilt.

private def menu_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

private def sample_menu(s)
  m = Crysterm::Widget::Menu.new(parent: s)
  m.add "Open"
  m.add "Save"
  m.add_separator
  m.add "Quit"
  m
end

describe "Menu render caches (ALLOCS Group J)" do
  it "lays out rows and separators correctly across two renders" do
    s = menu_screen
    m = sample_menu s
    s._render

    # Four rows: Open, Save, ───, Quit.
    m.@items.size.should eq 4

    inner = m.awidth - m.ihorizontal
    # The separator row is stretched to the full inner width with box-drawing.
    sep = m.@items[2]
    m.@separator_items.includes?(sep).should be_true
    sep.content.should eq "─" * inner

    # Non-separator rows carry their labels and are laid to the content width.
    m.@items[0].content.should contain("Open")
    m.@items[3].content.should contain("Quit")
    first_content = m.@items[0].content

    # A second render with nothing changed must not alter the laid-out content.
    s._render
    m.@items[0].content.should eq first_content
    sep.content.should eq "─" * inner
  end

  it "reuses the cached visible-actions and column arrays when unchanged" do
    s = menu_screen
    m = sample_menu s
    s._render

    va = m.@visible_actions
    lefts = m.@row_lefts
    rights = m.@row_rights
    va.size.should eq 4

    s._render
    # Same array objects: `#sync_items` did not run, so nothing was rebuilt.
    m.@visible_actions.same?(va).should be_true
    m.@row_lefts.same?(lefts).should be_true
    m.@row_rights.same?(rights).should be_true
  end

  it "skips re-laying rows when neither width nor rows changed" do
    s = menu_screen
    m = sample_menu s
    s._render

    laid = m.@last_laid_inner
    laid.should be > 0
    m.@rows_dirty.should be_false # cleared after the first layout

    s._render
    m.@last_laid_inner.should eq laid
    m.@rows_dirty.should be_false
  end

  it "reuses the derived separator render style across frames" do
    s = menu_screen
    m = sample_menu s
    s._render

    sep_style = m.@sep_style_out
    sep_style.should_not be_nil

    s._render
    m.@sep_style_out.same?(sep_style).should be_true
  end

  it "rebuilds the caches when an action is added" do
    s = menu_screen
    m = sample_menu s
    s._render

    va = m.@visible_actions
    m.add "New" # `#sync_items` runs, rebuilding the caches
    m.@visible_actions.same?(va).should be_false
    m.@rows_dirty.should be_true
    m.@visible_actions.size.should eq 5

    s._render
    m.@items.size.should eq 5
    m.@items.last.content.should contain("New")
  end
end
