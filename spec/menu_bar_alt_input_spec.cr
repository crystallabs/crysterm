require "./spec_helper"

include Crysterm

# Alt+letter end-to-end from RAW INPUT BYTES: the terminal's two real
# encodings — legacy `ESC f` and the enhanced keyboard protocol's CSI-u
# (`\e[102;3u`, mods 3 = 1 + alt bit 2) — must both travel through `Tput`'s
# byte parser, `Window#handle_input`, and the `MenuBar`'s window-level
# mnemonic handler, ending with the menu open. Guards the whole input chain
# the synthetic-`Event::KeyPress` specs bypass.

private def alt_screen(bytes : String)
  input = IO::Memory.new bytes
  s = Crysterm::Window.new input: input, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: 24, default_quit_keys: false
  bar = Crysterm::Widget::MenuBar.new parent: s, top: 0, left: 0, width: 40, height: 1
  bar.add_menu "&File", [Crysterm::Action.new("New")]
  bar.add_menu "&Edit", [Crysterm::Action.new("Cut")]
  central = Crysterm::Widget::Box.new parent: s, keys: true, top: 5, left: 0, width: 10, height: 1
  s.repaint
  central.focus
  # Drive the parser synchronously: `listen` ends at the memory IO's EOF.
  s.screen.tput.listen { |e| s.handle_input e }
  {s, bar}
end

describe "MenuBar Alt+letter from raw input bytes" do
  it "opens the menu on legacy ESC+letter" do
    _s, bar = alt_screen "\ee"
    bar.open_index.should eq 1
    bar.menus[1].current_index.should eq 0 # keyboard-opened: first entry selected
  end

  it "opens the menu on an enhanced-protocol alt-modified letter" do
    _s, bar = alt_screen "\e[101;3u" # 'e' (101), mods 3 = alt
    bar.open_index.should eq 1
  end

  it "does not open on the bare letter or bare Escape" do
    _s, bar = alt_screen "e"
    bar.open_index.nil?.should be_true
    _s2, bar2 = alt_screen "\e"
    bar2.open_index.nil?.should be_true
  end
end
