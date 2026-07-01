require "./spec_helper"
require "file_utils"

# Minimal host mixing in `Crysterm::Helpers` so `find_file` (an instance method)
# is instantiated and type-checked. It carried a latent nil-deref: `File.info` is
# wrapped in a `rescue` returning nil, so `stat : File::Info?`, and
# `stat.directory?` is a `Nil`-method compile error. This never surfaced since
# nothing else calls `find_file` (only its own recursion), so Crystal never
# compiled its body.
private class HelpersHost
  include Crysterm::Helpers
end

describe Crysterm::Helpers do
  describe "#find_file" do
    it "locates a file nested in a subdirectory" do
      root = File.join(Dir.tempdir, "crysterm_find_#{Random.rand(1_000_000)}")
      begin
        Dir.mkdir_p File.join(root, "a", "b")
        target = File.join(root, "a", "b", "needle.txt")
        File.write target, "x"

        HelpersHost.new.find_file(root, "needle.txt").should eq target
      ensure
        FileUtils.rm_rf root
      end
    end

    it "returns nil when the file is absent (and does not raise on unstattable entries)" do
      root = File.join(Dir.tempdir, "crysterm_find_#{Random.rand(1_000_000)}")
      begin
        Dir.mkdir_p root
        # The rescue path yielding a nil `stat` must not crash the directory walk.
        File.write File.join(root, "plain.txt"), "y"

        HelpersHost.new.find_file(root, "missing.txt").should be_nil
      ensure
        FileUtils.rm_rf root
      end
    end
  end
end
