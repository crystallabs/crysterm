require "./spec_helper"

include Crysterm

# FORMAL-WIDGETS Part B / B8 — shared behavioral conformance for the paged
# container family (`StackedWidget`, `TabWidget`, `ToolBox`, `Wizard`). Only the
# *adding* verb still differs per widget (`add_page`/`add_tab`/`add_item`); the
# selection contract (`count`, `current_index`/`current_index=`,
# `current_widget`/`current_widget=`, `Event::CurrentChanged`) is one shared
# `Mixin::PagedContainer`, so the adapter differs only where it must. Pins the
# empty-state contract — `current_index == -1` and the current widget is `nil`,
# never the *last* element — which is the live B0.1 drift (`ToolBox` used to
# return the last section for an empty toolbox).

private def mem_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

# `current_widget` / `set_current` are nil for `Wizard` (no per-index widget
# getter and no direct index setter — it navigates via `advance`/`back`).
private record PagedCase,
  name : String,
  build : Proc(Crysterm::Window, Crysterm::Widget),
  add : Proc(Crysterm::Widget, Crysterm::Widget, Nil),
  current_index : Proc(Crysterm::Widget, Int32),
  current_widget : Proc(Crysterm::Widget, Crysterm::Widget?)?,
  set_current : Proc(Crysterm::Widget, Int32, Nil)?

private def new_page
  Crysterm::Widget::Box.new
end

private def it_behaves_like_a_paged_container(c : PagedCase)
  describe c.name do
    it "reports an empty container as index -1 with no current widget (not the last)" do
      s = mem_screen
      w = c.build.call s
      c.current_index.call(w).should eq -1
      if cw = c.current_widget
        cw.call(w).should be_nil
      end
    end

    it "makes the first added page current" do
      s = mem_screen
      w = c.build.call s
      p1 = new_page
      c.add.call w, p1
      c.current_index.call(w).should eq 0
      if cw = c.current_widget
        cw.call(w).should be(p1)
      end
    end

    it "keeps the first page current when more are added" do
      s = mem_screen
      w = c.build.call s
      p1 = new_page
      p2 = new_page
      c.add.call w, p1
      c.add.call w, p2
      c.current_index.call(w).should eq 0
    end

    if setter = c.set_current
      it "switches the current page on demand" do
        s = mem_screen
        w = c.build.call s
        c.add.call w, new_page
        c.add.call w, new_page
        setter.call w, 1
        c.current_index.call(w).should eq 1
      end
    end
  end
end

describe "Paged container conformance (B8)" do
  it_behaves_like_a_paged_container PagedCase.new(
    name: "StackedWidget",
    build: ->(s : Crysterm::Window) { Crysterm::Widget::StackedWidget.new(parent: s, width: 30, height: 10).as(Crysterm::Widget) },
    add: ->(w : Crysterm::Widget, p : Crysterm::Widget) { w.as(Crysterm::Widget::StackedWidget).add_page p; nil },
    current_index: ->(w : Crysterm::Widget) { w.as(Crysterm::Widget::StackedWidget).current_index },
    current_widget: ->(w : Crysterm::Widget) { w.as(Crysterm::Widget::StackedWidget).current_widget },
    set_current: ->(w : Crysterm::Widget, i : Int32) { w.as(Crysterm::Widget::StackedWidget).current_index = i; nil },
  )

  it_behaves_like_a_paged_container PagedCase.new(
    name: "TabWidget",
    build: ->(s : Crysterm::Window) { Crysterm::Widget::TabWidget.new(parent: s, width: 40, height: 12).as(Crysterm::Widget) },
    add: ->(w : Crysterm::Widget, p : Crysterm::Widget) { w.as(Crysterm::Widget::TabWidget).add_tab "t", p; nil },
    current_index: ->(w : Crysterm::Widget) { w.as(Crysterm::Widget::TabWidget).current_index },
    current_widget: ->(w : Crysterm::Widget) { w.as(Crysterm::Widget::TabWidget).current_widget },
    set_current: ->(w : Crysterm::Widget, i : Int32) { w.as(Crysterm::Widget::TabWidget).current_index = i; nil },
  )

  it_behaves_like_a_paged_container PagedCase.new(
    name: "ToolBox",
    build: ->(s : Crysterm::Window) { Crysterm::Widget::ToolBox.new(parent: s, width: 30, height: 16).as(Crysterm::Widget) },
    add: ->(w : Crysterm::Widget, p : Crysterm::Widget) { w.as(Crysterm::Widget::ToolBox).add_item "t", p; nil },
    current_index: ->(w : Crysterm::Widget) { w.as(Crysterm::Widget::ToolBox).current_index },
    current_widget: ->(w : Crysterm::Widget) { w.as(Crysterm::Widget::ToolBox).current_widget },
    set_current: ->(w : Crysterm::Widget, i : Int32) { w.as(Crysterm::Widget::ToolBox).current_index = i; nil },
  )

  it_behaves_like_a_paged_container PagedCase.new(
    name: "Wizard",
    build: ->(s : Crysterm::Window) { Crysterm::Widget::Wizard.new(parent: s, width: 50, height: 16).as(Crysterm::Widget) },
    add: ->(w : Crysterm::Widget, p : Crysterm::Widget) { w.as(Crysterm::Widget::Wizard).add_page p; nil },
    current_index: ->(w : Crysterm::Widget) { w.as(Crysterm::Widget::Wizard).current_index },
    current_widget: nil, # navigates by step; no per-index widget getter
    set_current: nil,    # advance/back only
  )
end
