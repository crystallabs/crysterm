require "./spec_helper"

include Crysterm

# A menu row's mnemonic letter against `vi_keys`: with the vi navigation on,
# `j`/`k`/`g`/`G` and `H`/`M`/`L` move the highlight as they do in any item
# view, and a row whose mnemonic is one of those letters is not fired by it —
# navigation wins over a same-letter mnemonic, as it does over the arrow
# keys. With `vi_keys` off the letter is the mnemonic alone.

private def type(menu, c : Char)
  menu.handle_key_press Crysterm::Event::KeyPress.new(c, nil)
end

private def build(s, vi_keys : Bool)
  menu = Widget::Menu.new parent: s, vi_keys: vi_keys
  fired = [] of String
  {"&Jump", "&Kill", "&Go", "&Home"}.each { |t| menu.add_action(t) { fired << t } }
  s.repaint
  menu.focus
  {menu, fired}
end

describe "Widget::Menu mnemonics under vi_keys" do
  it "moves the highlight on j/k/G/H instead of firing the rows with those mnemonics" do
    s = headless_screen(40, 12)
    menu, fired = build(s, true)
    type menu, 'j' # reveals the highlight on the first row
    menu.selected_action.not_nil!.text.should eq "&Jump"
    type menu, 'j'
    menu.selected_action.not_nil!.text.should eq "&Kill"
    type menu, 'k'
    menu.selected_action.not_nil!.text.should eq "&Jump"
    type menu, 'G'
    menu.selected_action.not_nil!.text.should eq "&Home"
    type menu, 'H'
    menu.selected_action.not_nil!.text.should eq "&Jump"
    fired.should be_empty
    type menu, 'g' # Go's mnemonic is vi's "first"
    menu.selected_action.not_nil!.text.should eq "&Jump"
    fired.should be_empty
  end

  it "fires the row on its mnemonic with vi_keys off" do
    s = headless_screen(40, 12)
    menu, fired = build(s, false)
    type menu, 'k'
    fired.should eq ["&Kill"]
    type menu, 'h'
    fired.should eq ["&Kill", "&Home"]
  end
end
