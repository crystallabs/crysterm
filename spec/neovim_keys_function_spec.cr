require "./spec_helper"

describe Crysterm::Neovim::Keys do
  it "names kitty's F13 and up, which have no legacy form" do
    Crysterm::Neovim::Keys.notation(Tput::KeyEvent.new(57376, 'u')).should eq "<F13>"
    Crysterm::Neovim::Keys.notation(Tput::KeyEvent.new(57398, 'u')).should eq "<F35>"
    Crysterm::Neovim::Keys.notation(Tput::KeyEvent.new(57383, 'u', Tput::Modifiers::Shift)).should eq "<S-F20>"
  end
end
