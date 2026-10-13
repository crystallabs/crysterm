require "./spec_helper"

# `Reactive.link`: two properties kept equal both ways, without echo, until
# the owner is destroyed or the link is disposed.
describe "Reactive.link" do
  it "gives b a's value, then keeps the two equal both ways" do
    a = Crysterm::Reactive.property 1
    b = Crysterm::Reactive.property 0
    link = Crysterm::Reactive.link a, b
    b.value.should eq 1
    a.value = 2
    b.value.should eq 2
    b.value = 3
    a.value.should eq 3
    link.disposed?.should be_false
  end

  it "notifies each side once per change, with no echo back" do
    a = Crysterm::Reactive.property "x"
    b = Crysterm::Reactive.property "x"
    Crysterm::Reactive.link a, b
    a_changes = 0
    b_changes = 0
    a.on_change { a_changes += 1 }
    b.on_change { b_changes += 1 }
    a.value = "y"
    {a_changes, b_changes}.should eq({1, 1})
    b.value = "z"
    {a_changes, b_changes}.should eq({2, 2})
    a.value = "z" # equal: nothing moves
    {a_changes, b_changes}.should eq({2, 2})
  end

  it "lets a handler on one side change it again without looping" do
    a = Crysterm::Reactive.property 0
    b = Crysterm::Reactive.property 0
    Crysterm::Reactive.link a, b
    # A side that clamps what it is given: b's handler rewrites b.
    b.on_change { b.value = 10 if b.value > 10 }
    a.value = 50
    b.value.should eq 10
    a.value.should eq 10
  end

  it "ends with the owner's destruction, or by hand" do
    window = Crysterm::Window.new input: IO::Memory.new, output: IO::Memory.new, width: 20, height: 5
    a = Crysterm::Reactive.property false
    b = Crysterm::Reactive.property false
    link = Crysterm::Reactive.link a, b, window
    a.value = true
    b.value.should be_true
    window.destroy
    link.disposed?.should be_true
    a.value = false
    b.value.should be_true
    b.value = false
    a.value = true
    b.value.should be_false

    c = Crysterm::Reactive.property 5
    d = Crysterm::Reactive.property 0
    link = Crysterm::Reactive.link c, d
    link.dispose
    link.disposed?.should be_true
    c.value = 6
    d.value.should eq 5
    link.dispose # idempotent
  end
end
