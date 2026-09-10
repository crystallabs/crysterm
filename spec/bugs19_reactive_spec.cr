require "./spec_helper"

# Reactive scheduler settling guarantees: a write performed inside an effect's
# own run does not re-run that effect, while writes from any other origin
# (another effect, or code outside any effect) still do; and a flush whose
# items keep waking one another raises instead of spinning forever.

describe Crysterm::Reactive do
  describe "self-writing effect" do
    it "settles: a write from within the effect's own run does not re-run it" do
      count = Crysterm::Reactive::Property.new 0
      runs = 0
      Crysterm::Reactive.effect do
        runs += 1
        count.value = count.value + 1
      end
      # Initial run reads 0 and writes 1; the self-write is not a re-trigger.
      runs.should eq 1
      count.peek.should eq 1
    end

    it "still re-runs on a write from outside any effect, then settles again" do
      count = Crysterm::Reactive::Property.new 0
      runs = 0
      Crysterm::Reactive.effect do
        runs += 1
        count.value = count.value + 1
      end
      runs.should eq 1

      count.value = 10 # external write: legitimate re-trigger
      runs.should eq 2
      count.peek.should eq 11 # the re-run read 10 and wrote 11, then settled
    end

    it "settles when the external write happens inside a batch" do
      count = Crysterm::Reactive::Property.new 0
      runs = 0
      Crysterm::Reactive.effect do
        runs += 1
        count.value = count.value + 1
      end
      runs.should eq 1

      Crysterm::Reactive.batch do
        Crysterm::Reactive.batch { count.value = 100 }
        runs.should eq 1 # nested close does not flush; only the outermost does
      end
      runs.should eq 2
      count.peek.should eq 101
    end

    it "keeps tracking its dependencies after a suppressed self-write" do
      count = Crysterm::Reactive::Property.new 0
      runs = 0
      Crysterm::Reactive.effect do
        runs += 1
        count.value = count.value + 1
      end
      # Two further external writes each produce exactly one re-run.
      count.value = 50
      count.value = 60
      runs.should eq 3
      count.peek.should eq 61
    end
  end

  describe "cross-effect propagation" do
    it "an effect written to by another effect still re-runs" do
      a = Crysterm::Reactive::Property.new 1
      b = Crysterm::Reactive::Property.new 0
      b_runs = 0
      Crysterm::Reactive.effect { b.value = a.value * 10 } # writer
      Crysterm::Reactive.effect { b_runs += 1; b.value }   # reader of the written prop
      b_runs.should eq 1

      a.value = 2 # writer re-runs, its write to b re-runs the reader
      b.peek.should eq 20
      b_runs.should eq 2
    end

    it "a multi-step effect chain propagates end to end" do
      a = Crysterm::Reactive::Property.new 1
      b = Crysterm::Reactive::Property.new 0
      c = Crysterm::Reactive::Property.new 0
      seen = [] of Int32
      Crysterm::Reactive.effect { b.value = a.value + 1 }
      Crysterm::Reactive.effect { c.value = b.value + 1 }
      Crysterm::Reactive.effect { seen << c.value }
      seen.should eq [3]

      a.value = 10
      b.peek.should eq 11
      c.peek.should eq 12
      seen.should eq [3, 12]
    end

    it "propagates through a Computed into a leaf effect" do
      a = Crysterm::Reactive::Property.new 2
      doubled = Crysterm::Reactive.computed { a.value * 2 }
      seen = [] of Int32
      Crysterm::Reactive.effect { seen << doubled.value }
      seen.should eq [4]

      a.value = 5
      seen.should eq [4, 10]
    end
  end

  describe "flush cycle cap" do
    it "raises on a two-effect cycle instead of hanging" do
      a = Crysterm::Reactive::Property.new 0
      b = Crysterm::Reactive::Property.new 0
      # Creation settles (the counter-write lands while the other effect is
      # still mid-run and is dropped); the cycle spins on the next external
      # write, where the flush cap turns it into an error.
      eff1 = Crysterm::Reactive.effect { b.value = a.value + 1 }
      eff2 = Crysterm::Reactive.effect { a.value = b.value + 1 }
      expect_raises(Exception, /did not settle/) do
        a.value = 100
      end
      eff1.dispose
      eff2.dispose
    end

    it "leaves the scheduler usable after the cycle error" do
      a = Crysterm::Reactive::Property.new 0
      b = Crysterm::Reactive::Property.new 0
      eff1 = Crysterm::Reactive.effect { b.value = a.value + 1 }
      eff2 = Crysterm::Reactive.effect { a.value = b.value + 1 }
      expect_raises(Exception, /did not settle/) do
        a.value = 100
      end
      eff1.dispose
      eff2.dispose

      # A fresh, acyclic effect on the same fiber works normally.
      c = Crysterm::Reactive::Property.new 1
      seen = [] of Int32
      Crysterm::Reactive.effect { seen << c.value }
      c.value = 2
      seen.should eq [1, 2]
    end
  end
end
