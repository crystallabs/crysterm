require "./spec_helper"

include Crysterm

# Behavioural contract of `Cache::Bounded` (and the `Cache` registry). These
# guarantees are relied on by every cache in the project: FIFO/LRU eviction, a
# memoizing `fetch` that also caches `nil` (negative caching), identity keying
# for `Style`-keyed memos, and registry enumeration/clearing.

# A key type with a coarse, non-identity `==`/`hash`, so value-equality and
# identity keying can be told apart: two distinct instances with the same tag
# are `==` but not `same?`.
private class Tagged
  getter tag : String

  def initialize(@tag)
  end

  def_equals_and_hash @tag
end

describe Cache::Bounded do
  describe "basic hash-like access" do
    it "stores, reads, and reports presence" do
      c = Cache::Bounded(String, Int32).new(0)
      c["a"] = 1
      c["a"].should eq 1
      c["a"]?.should eq 1
      c.has_key?("a").should be_true
      c.has_key?("b").should be_false
      c["b"]?.should be_nil
      c.size.should eq 1
    end

    it "raises KeyError on missing [] but not on []?" do
      c = Cache::Bounded(String, Int32).new(0)
      expect_raises(KeyError) { c["missing"] }
      c["missing"]?.should be_nil
    end

    it "deletes and clears" do
      c = Cache::Bounded(String, Int32).new(0)
      c["a"] = 1
      c["b"] = 2
      c.delete("a").should eq 1
      c.delete("a").should be_nil
      c.has_key?("a").should be_false
      c.clear
      c.size.should eq 0
    end
  end

  describe "FIFO eviction (default)" do
    it "drops the oldest entry once over capacity" do
      c = Cache::Bounded(Int32, Int32).new(2)
      c[1] = 1
      c[2] = 2
      c[3] = 3 # evicts key 1 (oldest inserted)
      c.size.should eq 2
      c.has_key?(1).should be_false
      c.has_key?(2).should be_true
      c.has_key?(3).should be_true
    end

    it "does not reorder on read (a plain read never rescues the oldest)" do
      c = Cache::Bounded(Int32, Int32).new(2)
      c[1] = 1
      c[2] = 2
      c[1]? # read of oldest — no effect under FIFO
      c[3] = 3
      c.has_key?(1).should be_false # still evicted despite the read
    end
  end

  describe "LRU eviction" do
    it "keeps the most-recently-read entry" do
      c = Cache::Bounded(Int32, Int32).new(2, lru: true)
      c[1] = 1
      c[2] = 2
      c[1]?    # promote key 1 to most-recently-used
      c[3] = 3 # evicts key 2, the least-recently-used
      c.has_key?(1).should be_true
      c.has_key?(2).should be_false
      c.has_key?(3).should be_true
    end
  end

  describe "unbounded" do
    it "never evicts when capacity <= 0" do
      c = Cache::Bounded(Int32, Int32).new(0)
      100.times { |i| c[i] = i }
      c.size.should eq 100
      c.has_key?(0).should be_true
    end
  end

  describe "#fetch" do
    it "computes and stores on a miss, returns cached on a hit" do
      c = Cache::Bounded(String, Int32).new(0)
      calls = 0
      c.fetch("a") { calls += 1; 42 }.should eq 42
      c.fetch("a") { calls += 1; 99 }.should eq 42 # cached, block not run
      calls.should eq 1
    end

    it "caches a nil result (negative caching)" do
      c = Cache::Bounded(String, Int32?).new(0)
      calls = 0
      c.fetch("x") { calls += 1; nil }.should be_nil
      c.fetch("x") { calls += 1; 7 }.should be_nil # nil was cached
      calls.should eq 1
      c.has_key?("x").should be_true
    end

    it "evicts when a fetched entry exceeds capacity" do
      c = Cache::Bounded(Int32, Int32).new(2)
      c.fetch(1) { 1 }
      c.fetch(2) { 2 }
      c.fetch(3) { 3 }
      c.size.should eq 2
      c.has_key?(1).should be_false
    end
  end

  describe "by_identity" do
    it "keys on object identity, not value equality" do
      c = Cache::Bounded(Tagged, Int32).new(0, by_identity: true)
      a1 = Tagged.new("x")
      a2 = Tagged.new("x") # == a1 but not same?
      c[a1] = 1
      c[a2] = 2
      c.size.should eq 2 # two distinct entries despite a1 == a2
      c[a1].should eq 1
      c[a2].should eq 2
    end

    it "keys on value equality by default" do
      c = Cache::Bounded(Tagged, Int32).new(0)
      a1 = Tagged.new("x")
      a2 = Tagged.new("x")
      c[a1] = 1
      c[a2] = 2 # overwrites: a1 == a2
      c.size.should eq 1
      c[a1].should eq 2
    end
  end
end

describe Cache do
  it "registers a cache and reports it in stats, then clears it via clear_all" do
    before = Cache.registry.size
    c = Cache::Bounded(String, Int32).new(8, "spec_registered", register: true)
    c["a"] = 1
    Cache.registry.size.should eq before + 1
    entry = Cache.stats.find { |s| s[:name] == "spec_registered" }
    entry.should_not be_nil
    entry.not_nil![:size].should eq 1
    entry.not_nil![:capacity].should eq 8

    Cache.clear_all
    c.size.should eq 0
  end

  it "does not register a cache by default" do
    before = Cache.registry.size
    Cache::Bounded(String, Int32).new(8, "spec_unregistered")
    Cache.registry.size.should eq before
  end
end
