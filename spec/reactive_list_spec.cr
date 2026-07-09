require "./spec_helper"

include Crysterm

# Phase-4 reactivity: `Reactive::ObservableList` + `Reactive.bind_items`, which
# patches an item view row-by-row from granular list deltas. See REACTIVE.md.

private def rx_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false,
    optimization: Crysterm::OptimizationFlag::DamageTracking)
end

private record Change, op : Crysterm::Reactive::ListOp, index : Int32, count : Int32

private def capture_changes(list)
  seen = [] of Change
  list.on(Crysterm::Event::ListChange) { |e| seen << Change.new(e.op, e.index, e.count) }
  seen
end

describe Crysterm::Reactive::ObservableList do
  it "reads like a collection" do
    l = Crysterm::Reactive::ObservableList(String).new %w[a b c]
    l.size.should eq 3
    l[1].should eq "b"
    l.to_a.should eq %w[a b c]
    l.map(&.upcase).should eq %w[A B C] # via Enumerable
  end

  it "emits a granular Insert on push and insert" do
    l = Crysterm::Reactive::ObservableList(String).new %w[a b]
    seen = capture_changes l
    l << "c"
    l.insert 0, "z"
    seen.should eq [
      Change.new(Crysterm::Reactive::ListOp::Insert, 2, 1),
      Change.new(Crysterm::Reactive::ListOp::Insert, 0, 1),
    ]
    l.to_a.should eq %w[z a b c]
  end

  it "emits Insert with a run count on concat" do
    l = Crysterm::Reactive::ObservableList(Int32).new [1]
    seen = capture_changes l
    l.concat [2, 3, 4]
    seen.should eq [Change.new(Crysterm::Reactive::ListOp::Insert, 1, 3)]
  end

  it "emits Remove on delete_at/pop/shift and Update on []=" do
    l = Crysterm::Reactive::ObservableList(String).new %w[a b c d]
    seen = capture_changes l
    l.delete_at 1
    l.pop
    l.shift
    l[0] = "X"
    seen.should eq [
      Change.new(Crysterm::Reactive::ListOp::Remove, 1, 1),
      Change.new(Crysterm::Reactive::ListOp::Remove, 2, 1),
      Change.new(Crysterm::Reactive::ListOp::Remove, 0, 1),
      Change.new(Crysterm::Reactive::ListOp::Update, 0, 1),
    ]
    l.to_a.should eq %w[X]
  end

  it "emits Reset on clear and replace" do
    l = Crysterm::Reactive::ObservableList(String).new %w[a b]
    seen = capture_changes l
    l.replace %w[x y z]
    l.clear
    seen.map(&.op).should eq [Crysterm::Reactive::ListOp::Reset, Crysterm::Reactive::ListOp::Reset]
    l.empty?.should be_true
  end
end

describe "Crysterm::Reactive.bind_items" do
  it "fills the view immediately from the list" do
    scr = rx_screen
    view = Crysterm::Widget::List.new parent: scr, top: 0, left: 0, width: 20, height: 6
    names = Crysterm::Reactive::ObservableList(String).new %w[Ada Alan Grace]
    Crysterm::Reactive.bind_items(view, names, &.itself)
    view.ritems.should eq %w[Ada Alan Grace]
    view.items.size.should eq 3
  end

  it "appends exactly the new row on push" do
    scr = rx_screen
    view = Crysterm::Widget::List.new parent: scr, width: 20, height: 6
    names = Crysterm::Reactive::ObservableList(String).new %w[Ada]
    Crysterm::Reactive.bind_items(view, names, &.itself)
    names << "Grace"
    view.ritems.should eq %w[Ada Grace]
  end

  it "inserts at the right position" do
    scr = rx_screen
    view = Crysterm::Widget::List.new parent: scr, width: 20, height: 6
    names = Crysterm::Reactive::ObservableList(String).new %w[a c]
    Crysterm::Reactive.bind_items(view, names, &.itself)
    names.insert 1, "b"
    view.ritems.should eq %w[a b c]
  end

  it "removes just the deleted row" do
    scr = rx_screen
    view = Crysterm::Widget::List.new parent: scr, width: 20, height: 6
    names = Crysterm::Reactive::ObservableList(String).new %w[a b c]
    Crysterm::Reactive.bind_items(view, names, &.itself)
    names.delete_at 1
    view.ritems.should eq %w[a c]
  end

  it "updates one row's content in place" do
    scr = rx_screen
    view = Crysterm::Widget::List.new parent: scr, width: 20, height: 6
    names = Crysterm::Reactive::ObservableList(String).new %w[a b c]
    Crysterm::Reactive.bind_items(view, names, &.itself)
    names[1] = "B"
    view.ritems.should eq %w[a B c]
  end

  it "rebuilds on reset (replace)" do
    scr = rx_screen
    view = Crysterm::Widget::List.new parent: scr, width: 20, height: 6
    names = Crysterm::Reactive::ObservableList(String).new %w[a b c]
    Crysterm::Reactive.bind_items(view, names, &.itself)
    names.replace %w[x y]
    view.ritems.should eq %w[x y]
  end

  it "renders arbitrary element types via the block" do
    scr = rx_screen
    view = Crysterm::Widget::List.new parent: scr, width: 20, height: 6
    nums = Crysterm::Reactive::ObservableList(Int32).new [1, 2, 3]
    Crysterm::Reactive.bind_items(view, nums) { |n| "##{n}" }
    view.ritems.should eq ["#1", "#2", "#3"]
    nums << 4
    view.ritems.should eq ["#1", "#2", "#3", "#4"]
  end

  it "schedules a repaint on change" do
    scr = rx_screen
    view = Crysterm::Widget::List.new parent: scr, width: 20, height: 6
    names = Crysterm::Reactive::ObservableList(String).new %w[a]
    Crysterm::Reactive.bind_items(view, names, &.itself)
    scr._render
    scr.@damage_dirty_roots.clear
    names << "b"
    scr.@damage_dirty_roots.empty?.should be_false
  end

  it "stops patching once the view is destroyed" do
    scr = rx_screen
    view = Crysterm::Widget::List.new parent: scr, width: 20, height: 6
    names = Crysterm::Reactive::ObservableList(String).new %w[a b]
    Crysterm::Reactive.bind_items(view, names, &.itself)
    view.destroy
    names << "c" # must not raise or touch the destroyed view
    view.ritems.should eq %w[a b]
  end
end
