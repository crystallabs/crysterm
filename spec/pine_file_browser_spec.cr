require "./spec_helper"

include Crysterm

private def pfb_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# Thin Pine-flavored subclass of `Widget::FileManager`: only changes defaults
# (reverse-video selected row, keyboard navigation on), no new file logic.
describe "Pine::FileBrowser" do
  it "defaults the selected style to reverse video (the Pine look)" do
    s = pfb_screen
    fb = Crysterm::Widget::Pine::FileBrowser.new parent: s, cwd: Dir.current
    fb.styles.selected.reverse?.should be_true
  end

  it "lists the entries of its directory" do
    s = pfb_screen
    fb = Crysterm::Widget::Pine::FileBrowser.new parent: s, cwd: Dir.current
    fb.refresh
    # Repo root (Dir.current) contains `src`; the rendered row decorates it
    # with color tags and a trailing slash.
    fb.item_texts.any?(&.includes?("src")).should be_true
    # `..` is always prepended as the first entry.
    fb.item_texts.any?(&.includes?("..")).should be_true
  end

  it "tracks the current directory" do
    s = pfb_screen
    fb = Crysterm::Widget::Pine::FileBrowser.new parent: s, cwd: Dir.current
    fb.cwd.should eq Dir.current
  end
end
