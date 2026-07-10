require "./spec_helper"

# Regression spec for two BUGS13 findings:
#
#   R2 — `ObservableList#insert` normalized a negative index but never
#        validated the result: a still-out-of-range index was handed to
#        `Array#insert`, which re-normalizes — so the array could mutate while
#        the emitted `Insert` carried the wrong (negative) index, permanently
#        desyncing a bound view. A plain `Array` raises `IndexError`.
#   R3 — `initialize`/`replace` did `@array = other.to_a`; for an `Array`
#        argument `#to_a` returns *self*, so the list aliased the caller's
#        array — external pushes desynced bound views, and list mutations
#        showed up in the caller's array.

include Crysterm

private record Change, op : Crysterm::Reactive::ListOp, index : Int32, count : Int32

private def capture_changes(list)
  seen = [] of Change
  list.on(Crysterm::Event::ListChange) { |e| seen << Change.new(e.op, e.index, e.count) }
  seen
end

describe "BUGS13 R2 — ObservableList#insert validates out-of-range indices" do
  it "raises IndexError for a too-negative index without mutating or emitting" do
    l = Crysterm::Reactive::ObservableList(String).new %w[a b c]
    seen = capture_changes l
    # -5 normalizes to -1 against size 3 (+1 append semantics) — still
    # negative; Array#insert would re-normalize it to an append while the
    # event said index -1.
    expect_raises(IndexError) { l.insert(-5, "x") }
    seen.should be_empty
    l.to_a.should eq %w[a b c]
  end

  it "raises IndexError for a too-large positive index without mutating or emitting" do
    l = Crysterm::Reactive::ObservableList(String).new %w[a b c]
    seen = capture_changes l
    expect_raises(IndexError) { l.insert(4, "x") }
    seen.should be_empty
    l.to_a.should eq %w[a b c]
  end

  it "still accepts the boundary indices 0, size and -1 (append)" do
    l = Crysterm::Reactive::ObservableList(String).new %w[a b]
    seen = capture_changes l
    l.insert(2, "c")  # index == size: append
    l.insert(0, "z")  # prepend
    l.insert(-1, "y") # -1: append after last
    l.to_a.should eq %w[z a b c y]
    seen.should eq [
      Change.new(Crysterm::Reactive::ListOp::Insert, 2, 1),
      Change.new(Crysterm::Reactive::ListOp::Insert, 0, 1),
      Change.new(Crysterm::Reactive::ListOp::Insert, 4, 1),
    ]
  end
end

describe "BUGS13 R3 — ObservableList copies an Array argument instead of aliasing it" do
  it "does not observe external mutations of the constructor argument" do
    src = %w[a b]
    l = Crysterm::Reactive::ObservableList(String).new src
    src << "external" # must not leak into the list
    l.to_a.should eq %w[a b]
    l.size.should eq 2
  end

  it "does not mutate the constructor argument through list ops" do
    src = %w[a b]
    l = Crysterm::Reactive::ObservableList(String).new src
    l << "c"
    l.delete_at 0
    src.should eq %w[a b]
  end

  it "copies the argument of #replace too" do
    src = %w[x y]
    l = Crysterm::Reactive::ObservableList(String).new
    l.replace src
    src << "external"
    l.to_a.should eq %w[x y]
    l.push "z"
    src.should eq %w[x y external]
  end

  it "still accepts non-Array enumerables" do
    l = Crysterm::Reactive::ObservableList(Int32).new(1..3)
    l.to_a.should eq [1, 2, 3]
    l.replace(5..6)
    l.to_a.should eq [5, 6]
  end
end
