require "./spec_helper"

include Crysterm

# `FileWatcher` (Qt's `QFileSystemWatcher`, by polling): one
# `Event::FileChanged` per watched path per detected change — a write, a
# deletion, an appearance — on the timer's fiber, or on a window's render
# fiber when given one.

# Waits for *n* events to have arrived, failing the example on a hang.
private def wait_for(seen : Array(String), n : Int32) : Nil
  wait_until(1.second) { seen.size >= n }
end

describe "FileWatcher" do
  it "reports a write, then a deletion, once each" do
    file = File.tempfile("crysterm-file-watcher")
    file.puts "one"
    file.flush
    watcher = FileWatcher.new 20.milliseconds
    begin
      seen = [] of String
      watcher.on(Event::FileChanged) { |e| seen << e.path }
      watcher.add_path file.path
      watcher.paths.should eq [file.path]
      watcher.running?.should be_true

      sleep 60.milliseconds
      seen.should be_empty # unchanged: nothing to report

      file.puts "two"
      file.flush
      wait_for seen, 1
      sleep 60.milliseconds
      seen.should eq [file.path]

      file.close
      File.delete file.path
      wait_for seen, 2
      sleep 60.milliseconds
      seen.should eq [file.path, file.path]
    ensure
      watcher.stop
      watcher.running?.should be_false
      File.delete? file.path
    end
  end

  it "reports a watched path appearing, and forgets a removed one" do
    path = File.tempname("crysterm-file-watcher")
    watcher = FileWatcher.new 20.milliseconds
    begin
      seen = [] of String
      watcher.on(Event::FileChanged) { |e| seen << e.path }
      watcher.add_path path
      File.write path, "here"
      wait_for seen, 1

      watcher.remove_path path
      watcher.paths.should be_empty
      File.delete path
      sleep 60.milliseconds
      seen.should eq [path]
    ensure
      watcher.stop
      File.delete? path
    end
  end

  it "stop pauses, start resumes and reports what changed meanwhile" do
    file = File.tempfile("crysterm-file-watcher")
    watcher = FileWatcher.new 20.milliseconds
    begin
      seen = [] of String
      watcher.on(Event::FileChanged) { |e| seen << e.path }
      watcher.add_path file.path
      watcher.stop
      file.puts "changed while stopped"
      file.flush
      sleep 60.milliseconds
      seen.should be_empty

      watcher.start
      watcher.running?.should be_true
      wait_for seen, 1
    ensure
      watcher.stop
      file.close
      File.delete? file.path
    end
  end

  it "ends with the window it was given" do
    w = headless_screen(40, 10)
    watcher = FileWatcher.new 20.milliseconds, window: w
    begin
      watcher.running?.should be_true
      w.destroy
      watcher.running?.should be_false
    ensure
      watcher.stop
      w.destroy
    end
  end

  it "does not put back a path a handler removed during the same look" do
    first = File.tempfile("crysterm-file-watcher-a")
    second = File.tempfile("crysterm-file-watcher-b")
    watcher = FileWatcher.new 20.milliseconds
    begin
      seen = [] of String
      watcher.on(Event::FileChanged) do |e|
        seen << e.path
        # The first path's handler drops the second, changed in the same look.
        watcher.remove_path second.path if e.path == first.path
      end
      watcher.add_path first.path
      watcher.add_path second.path
      watcher.stop # both changes land in one look, in insertion order
      [first, second].each do |f|
        f.puts "changed"
        f.flush
      end
      watcher.start
      wait_for seen, 1
      sleep 60.milliseconds
      seen.should eq [first.path]
      watcher.paths.should eq [first.path]
    ensure
      watcher.stop
      [first, second].each do |f|
        f.close
        File.delete? f.path
      end
    end
  end

  it "delivers through the window's render fiber when given one" do
    w = headless_screen(40, 10)
    file = File.tempfile("crysterm-file-watcher")
    watcher = FileWatcher.new 20.milliseconds, window: w
    begin
      watcher.window.should be w
      seen = Channel(String).new(1)
      watcher.on(Event::FileChanged) { |e| seen.send e.path }
      watcher.add_path file.path
      file.puts "two"
      file.flush
      select
      when p = seen.receive
        p.should eq file.path
      when timeout(1.second)
        fail "the change never arrived through the window"
      end
    ensure
      watcher.stop
      w.destroy
      file.close
      File.delete? file.path
    end
  end
end
