require "./spec_helper"
require "file_utils"

include Crysterm

# A scratch tree: `a.md`, `ab.md`, a directory `adir` holding `inner.md`, and
# a file with a glob character in its name.
private def with_tree(&)
  dir = File.tempname("line_prompt_paths")
  Dir.mkdir_p File.join(dir, "adir")
  File.write File.join(dir, "a.md"), ""
  File.write File.join(dir, "ab.md"), ""
  File.write File.join(dir, "adir", "inner.md"), ""
  File.write File.join(dir, "b[1].md"), ""
  yield dir
ensure
  FileUtils.rm_rf dir if dir
end

describe "Widget::LinePrompt.path_completer" do
  it "lists the matching entries sorted, directories with a trailing slash" do
    with_tree do |dir|
      complete = Widget::LinePrompt.path_completer
      complete.call(File.join(dir, "a")).should eq [
        File.join(dir, "a.md"),
        File.join(dir, "ab.md"),
        File.join(dir, "adir/"),
      ]
    end
  end

  it "descends into a directory given with its slash" do
    with_tree do |dir|
      complete = Widget::LinePrompt.path_completer
      complete.call(File.join(dir, "adir/")).should eq [File.join(dir, "adir", "inner.md")]
    end
  end

  it "returns nothing for a text nothing starts with" do
    with_tree do |dir|
      Widget::LinePrompt.path_completer.call(File.join(dir, "zzz")).should be_empty
    end
  end

  it "takes glob characters in the text literally" do
    with_tree do |dir|
      complete = Widget::LinePrompt.path_completer
      complete.call(File.join(dir, "b[")).should eq [File.join(dir, "b[1].md")]
    end
  end

  it "expands a leading ~ to the home directory" do
    complete = Widget::LinePrompt.path_completer
    home = Path.home.to_s
    complete.call("~").should eq ["#{home}/"]
    complete.call("~/").each &.should start_with("#{home}/")
  end

  it "cycles the prompt's field through the completions on Tab" do
    with_tree do |dir|
      s = headless_screen(40, 3)
      cl = Widget::LinePrompt.new parent: s, bottom: 0, left: 0, width: "100%"
      cl.completer = Widget::LinePrompt.path_completer
      cl.prompt("Open: ", File.join(dir, "a")) { }
      s.repaint
      cl.field.emit Event::KeyPress.new('\0', Tput::Key::Tab)
      cl.field.value.should eq File.join(dir, "a.md")
      cl.field.emit Event::KeyPress.new('\0', Tput::Key::Tab)
      cl.field.value.should eq File.join(dir, "ab.md")
    end
  end

  it "takes a lone directory match and descends into it on the next Tab" do
    with_tree do |dir|
      s = headless_screen(40, 3)
      cl = Widget::LinePrompt.new parent: s, bottom: 0, left: 0, width: "100%"
      cl.completer = Widget::LinePrompt.path_completer
      cl.prompt("Open: ", File.join(dir, "ad")) { }
      s.repaint
      cl.field.emit Event::KeyPress.new('\0', Tput::Key::Tab)
      cl.field.value.should eq File.join(dir, "adir/")
      cl.field.emit Event::KeyPress.new('\0', Tput::Key::Tab)
      cl.field.value.should eq File.join(dir, "adir", "inner.md")
    end
  end
end
