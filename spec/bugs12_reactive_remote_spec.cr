require "./spec_helper"

# Regression spec for three BUGS12 findings:
#
#   #39 — ObservableList emitted raw negative indices, silently desyncing
#         `bind_items` views (which bail on a negative row index).
#   #40 — `Reactive.flush` dropped every binding queued after one that raised.
#   #41 — `HTTPBridge#quit` could block a fiber forever on a capacity-1 shutdown
#         channel (guarded by -Dremote like every other bridge spec).
#
# Run both ways so the file always compiles; -Dremote also exercises #41:
#   crystal spec -Dremote spec/bugs12_reactive_remote_spec.cr
#   crystal spec          spec/bugs12_reactive_remote_spec.cr

include Crysterm

private record Change, op : Crysterm::Reactive::ListOp, index : Int32, count : Int32

private def capture_changes(list)
  seen = [] of Change
  list.on(Crysterm::Event::ListChanged) { |e| seen << Change.new(e.op, e.index, e.count) }
  seen
end

# A trivial `Deferrable` for exercising `Reactive.flush` directly.
private class RunSpy
  include Crysterm::Reactive::Deferrable
  getter ran = false

  def initialize(@raises : Bool = false)
  end

  def run : Nil
    @ran = true
    raise "boom" if @raises
  end
end

describe "BUGS12 #39 — ObservableList normalizes negative indices" do
  it "emits Insert at the resolved (positive) slot for a negative insert" do
    l = Crysterm::Reactive::ObservableList(String).new %w[a b c]
    seen = capture_changes l
    # `insert(-1, x)` appends *after* the last element — slot 3 on a size-3 list.
    l.insert(-1, "z")
    seen.should eq [Change.new(Crysterm::Reactive::ListOp::Insert, 3, 1)]
    l.to_a.should eq %w[a b c z]
  end

  it "emits Update at the resolved slot for a negative []=" do
    l = Crysterm::Reactive::ObservableList(String).new %w[a b c]
    seen = capture_changes l
    l[-1] = "Z!"
    seen.should eq [Change.new(Crysterm::Reactive::ListOp::Update, 2, 1)]
    l.to_a.should eq %w[a b Z!]
  end

  it "emits Remove at the resolved slot for a negative delete_at" do
    l = Crysterm::Reactive::ObservableList(String).new %w[a b c]
    seen = capture_changes l
    l.delete_at(-1).should eq "c"
    seen.should eq [Change.new(Crysterm::Reactive::ListOp::Remove, 2, 1)]
    l.to_a.should eq %w[a b]
  end

  it "keeps a bound view in sync through negative-index mutations" do
    scr = Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new,
      error: IO::Memory.new, width: 80, height: 24, default_quit_keys: false)
    view = Crysterm::Widget::List.new parent: scr, width: 20, height: 6
    list = Crysterm::Reactive::ObservableList(String).new %w[a b c]
    Crysterm::Reactive.bind_items(view, list, &.itself)
    view.item_texts.should eq %w[a b c]

    list.insert(-1, "z") # append
    view.item_texts.should eq %w[a b c z]

    list[-1] = "Z!" # update last
    view.item_texts.should eq %w[a b c Z!]

    list.delete_at(-2) # remove "c"
    view.item_texts.should eq %w[a b Z!]
  end
end

describe "BUGS12 #40 — Reactive.flush runs every queued item despite a raise" do
  it "runs all deferred items even when one raises, then re-raises the first" do
    a = RunSpy.new
    boom = RunSpy.new raises: true
    b = RunSpy.new

    expect_raises(Exception, "boom") do
      Crysterm::Reactive.batch do
        Crysterm::Reactive.enqueue a
        Crysterm::Reactive.enqueue boom
        Crysterm::Reactive.enqueue b
      end
    end

    a.ran.should be_true
    boom.ran.should be_true
    b.ran.should be_true # queued after the raiser — must not be dropped
  end
end

{% if flag?(:remote) %}
  describe "BUGS12 #41 — HTTPBridge#quit is idempotent and never blocks" do
    it "returns promptly on repeated quit calls" do
      screen = Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new,
        error: IO::Memory.new, width: 80, height: 24, default_quit_keys: false)
      bridge = Crysterm::HTTPBridge.new screen

      done = Channel(Nil).new(1)
      spawn do
        # Under the old capacity-1 `send`, the second call blocks forever (buffer
        # full, no receiver); closing the channel makes every call idempotent.
        bridge.quit
        bridge.quit
        bridge.quit
        done.send nil
      end

      select
      when done.receive
        # ok — all three quits completed without wedging a fiber
      when timeout(2.seconds)
        fail "HTTPBridge#quit blocked on a repeated call"
      end
    end
  end
{% end %}
