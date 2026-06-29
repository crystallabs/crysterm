require "./spec_helper"

include Crysterm

private def abp_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# `Mixin::ActionBar#render` (the layout pass behind `Widget::ListBar`,
# `MenuBar`, `ToolBar`) positions each item box with a *content-relative* left
# (0 == the bar's content origin). `Widget#aleft` already folds the parent's
# `ileft` (border + left padding) into a child's relative `left`, so the render
# cursor must start at 0, not at `ileft`. Starting at `ileft` double-counted the
# inset and shoved every item right by `ileft` (pushing the last items off the
# right edge) on any bar with a border or left padding. A borderless,
# zero-padding bar hides the bug (`ileft == 0`), so a left-padded bar is used.
describe "Mixin::ActionBar#render content origin" do
  it "places the first item at the content origin (not double-inset) under left padding" do
    s = abp_screen
    bar = Crysterm::Widget::ListBar.new parent: s, width: 80, height: 1
    bar.style.padding = Crysterm::Padding.new 4, 0, 0, 0
    bar.set_items ["a", "b", "c"]
    s._render

    bar.ileft.should eq 4
    first = bar.items[0]
    # The first visible item must sit exactly at the bar's content origin
    # (bar.aleft + bar.ileft), i.e. its relative `left` resolves with the inset
    # applied once — not twice.
    first.aleft.should eq(bar.aleft + bar.ileft)
  end

  it "keeps successive items packed by their own widths from the content origin" do
    s = abp_screen
    bar = Crysterm::Widget::ListBar.new parent: s, width: 80, height: 1
    bar.style.padding = Crysterm::Padding.new 4, 0, 0, 0
    bar.set_items ["a", "b"]
    s._render

    a = bar.items[0]
    b = bar.items[1]
    # Second item starts one item-gap past the first item's right edge, all
    # measured from the shared content origin.
    b.aleft.should eq(a.aleft + (a.awidth || 0) + bar.item_gap)
  end
end
