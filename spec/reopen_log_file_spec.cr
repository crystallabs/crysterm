require "./spec_helper"
require "file_utils"

# `Crysterm.reopen_log_file`: the `log.file` option's file opened anew, for
# an application that removed or rotated it while running. The log is
# installed once per process, so the examples share the installed file:
# the one `.install_log_file` opened here, in a scratch directory the run
# removes.
describe "Crysterm.reopen_log_file" do
  dir = File.tempname("crysterm-log")
  Dir.mkdir_p dir
  log = File.join(dir, "app.log")
  previous = Crysterm::Config.log_file

  it "is false while no log file is installed" do
    Crysterm::Config.set "log.file", log
    Crysterm.reopen_log_file.should be_false
  end

  it "makes the removed file anew and logs into it" do
    Crysterm::Config.set "log.file", log
    Crysterm.install_log_file
    File.exists?(log).should be_true
    Log.info { "before" }
    File.read(log).should contain "before"
    File.delete log
    Log.info { "lost" } # into the unlinked inode
    Crysterm.reopen_log_file.should be_true
    File.exists?(log).should be_true
    Log.info { "after" }
    text = File.read(log)
    text.should contain "after"
    text.should_not contain "before"
    text.should_not contain "lost"
  end

  it "keeps the file it has when the new one cannot be opened" do
    Crysterm::Config.set "log.file", File.join(File.tempname("crysterm-no-such-dir"), "app.log")
    Crysterm.reopen_log_file.should be_false
    Crysterm::Config.set "log.file", log
    Log.info { "still here" }
    File.read(log).should contain "still here"
  end

  it "is false with the option emptied" do
    Crysterm::Config.set "log.file", ""
    Crysterm.reopen_log_file.should be_false
    Crysterm::Config.set "log.file", log
  end

  it "cleans up" do
    Crysterm::Config.set "log.file", previous
    FileUtils.rm_rf dir
  end
end
