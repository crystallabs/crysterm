require "./spec_helper"

include Crysterm

# Regression spec for the menu per-frame allocation caches.
#
# A menu's `#paint` runs `#fit_width`/`#fit_height`/`#size_rows` and re-docks
# its separators every frame. The derived data is cached instead of rebuilt
# per frame:
#   * separator dock-row indices reuse `@merge_junction_rows_buf`.
#   * `@visible_actions` / `@row_lefts` / `@row_rights` rebuilt only in
#     `#sync_items`; `#size_rows` early-returns on an unchanged width.
#   * `#fit_width`/`#fit_height` read the cached visible-actions array.
#   * `#item_on_surface` caches the surfaced style per source style.
#   * `#separator_render_style` caches the derived line style.
#
# These specs render a menu (separators + multiple actions) twice and assert
# (a) the content is laid out correctly and (b) the cached arrays/styles are the
# *same objects* on the second render, i.e. nothing was rebuilt.

private def sample_menu(s)
  m = Crysterm::Widget::Menu.new(parent: s)
  m.add_action "Open"
  m.add_action "Save"
  m.add_separator
  m.add_action "Quit"
  m
end

describe "Menu render caches (ALLOCS Group J)" do
  it "lays out rows and separators correctly across two renders" do
    s = headless_screen(80, 24)
    m = sample_menu s
    s.repaint

    # Four rows: Open, Save, ───, Quit.
    m.@item_boxes.size.should eq 4

    inner = m.awidth - m.ihorizontal
    # The separator row is stretched to the full inner width with box-drawing.
    sep = m.@item_boxes[2]
    m.@separator_items.includes?(sep).should be_true
    sep.content.should eq "─" * inner

    # Non-separator rows carry their labels and are laid to the content width.
    m.@item_boxes[0].content.should contain("Open")
    m.@item_boxes[3].content.should contain("Quit")
    first_content = m.@item_boxes[0].content

    # A second render with nothing changed must not alter the laid-out content.
    s.repaint
    m.@item_boxes[0].content.should eq first_content
    sep.content.should eq "─" * inner
  end

  it "reuses the cached visible-actions and column arrays when unchanged" do
    s = headless_screen(80, 24)
    m = sample_menu s
    s.repaint

    va = m.@visible_actions
    lefts = m.@row_lefts
    rights = m.@row_rights
    va.size.should eq 4

    s.repaint
    # Same array objects: `#sync_items` did not run, so nothing was rebuilt.
    m.@visible_actions.same?(va).should be_true
    m.@row_lefts.same?(lefts).should be_true
    m.@row_rights.same?(rights).should be_true
  end

  it "skips re-laying rows when neither width nor rows changed" do
    s = headless_screen(80, 24)
    m = sample_menu s
    s.repaint

    laid = m.@last_laid_inner
    laid.should be > 0
    m.@rows_dirty.should be_false # cleared after the first layout

    s.repaint
    m.@last_laid_inner.should eq laid
    m.@rows_dirty.should be_false
  end

  it "reuses the derived separator render style across frames" do
    s = headless_screen(80, 24)
    m = sample_menu s
    s.repaint

    sep_style = m.@sep_style_out
    sep_style.should_not be_nil

    s.repaint
    m.@sep_style_out.same?(sep_style).should be_true
  end

  it "rebuilds the caches when an action is added" do
    s = headless_screen(80, 24)
    m = sample_menu s
    s.repaint

    va = m.@visible_actions
    m.add_action "New" # `#sync_items` runs, rebuilding the caches
    m.@visible_actions.same?(va).should be_false
    m.@rows_dirty.should be_true
    m.@visible_actions.size.should eq 5

    s.repaint
    m.@item_boxes.size.should eq 5
    m.@item_boxes.last.content.should contain("New")
  end
end
