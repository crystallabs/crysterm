require "./spec_helper"
require "file_utils"

# `Crysterm.default_log_file`: fills an empty `log.file` option with the
# application's per-user cache file as its default, creating the directory;
# leaves a configured file alone. Each example starts from the option's
# built-in state and puts the empty default back, so no example sees
# another's.
describe "Crysterm.default_log_file" do
  it "defaults log.file to the XDG cache file for the app, once" do
    previous = Crysterm::Config.log_file
    previous_xdg = ENV["XDG_CACHE_HOME"]?
    dir = File.tempname("crysterm-cache")
    begin
      ENV["XDG_CACHE_HOME"] = dir
      Crysterm::Config.reset "log.file"
      path = Crysterm.default_log_file("myapp")
      path.should eq File.join(dir, "myapp", "myapp.log")
      Crysterm::Config.log_file.should eq path
      Crysterm::Config.configured?("log.file").should be_false # a default, not a setting
      Dir.exists?(File.join(dir, "myapp")).should be_true
      # Already set: kept, whatever the app name.
      Crysterm.default_log_file("other").should eq path
      Crysterm::Config.log_file.should eq path
    ensure
      Crysterm::Config.reset "log.file"
      Crysterm::Config.set_default "log.file", ""
      Crysterm::Config.set "log.file", previous unless previous.empty?
      previous_xdg ? (ENV["XDG_CACHE_HOME"] = previous_xdg) : ENV.delete("XDG_CACHE_HOME")
      FileUtils.rm_rf dir
    end
  end

  it "keeps a configured file" do
    previous = Crysterm::Config.log_file
    begin
      Crysterm::Config.set "log.file", "/tmp/elsewhere.log"
      Crysterm.default_log_file("myapp").should eq "/tmp/elsewhere.log"
      Crysterm::Config.log_file.should eq "/tmp/elsewhere.log"
    ensure
      Crysterm::Config.set "log.file", previous
    end
  end

  it "returns nil and leaves the option empty when the directory cannot be made" do
    previous = Crysterm::Config.log_file
    previous_xdg = ENV["XDG_CACHE_HOME"]?
    file = File.tempfile("crysterm-not-a-dir")
    begin
      ENV["XDG_CACHE_HOME"] = file.path # a file where a directory is needed
      Crysterm::Config.reset "log.file"
      Crysterm.default_log_file("myapp").should be_nil
      Crysterm::Config.log_file.should eq ""
    ensure
      Crysterm::Config.reset "log.file"
      Crysterm::Config.set_default "log.file", ""
      Crysterm::Config.set "log.file", previous unless previous.empty?
      previous_xdg ? (ENV["XDG_CACHE_HOME"] = previous_xdg) : ENV.delete("XDG_CACHE_HOME")
      file.delete
    end
  end
end
