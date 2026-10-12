require "./spec_helper"

private alias K = Crysterm::Neovim::Keys

describe Crysterm::Neovim::Keys do
  it "names the numeric keypad's keys as Neovim does, <kEnter>, <k0>, <kPlus>, …" do
    # Application keypad mode (DECKPAM), which Crysterm turns on.
    K.notation(Tput::KeyEvent.from_ss3_keypad('M').not_nil!).should eq "<kEnter>"
    K.notation(Tput::KeyEvent.from_ss3_keypad('p').not_nil!).should eq "<k0>"
    K.notation(Tput::KeyEvent.from_ss3_keypad('y').not_nil!).should eq "<k9>"
    K.notation(Tput::KeyEvent.from_ss3_keypad('k').not_nil!).should eq "<kPlus>"
    K.notation(Tput::KeyEvent.from_ss3_keypad('m').not_nil!).should eq "<kMinus>"
    K.notation(Tput::KeyEvent.from_ss3_keypad('j').not_nil!).should eq "<kMultiply>"
    K.notation(Tput::KeyEvent.from_ss3_keypad('o').not_nil!).should eq "<kDivide>"
    K.notation(Tput::KeyEvent.from_ss3_keypad('n').not_nil!).should eq "<kPoint>"
    K.notation(Tput::KeyEvent.from_ss3_keypad('l').not_nil!).should eq "<kComma>"
    K.notation(Tput::KeyEvent.from_ss3_keypad('X').not_nil!).should eq "<kEqual>"
    # The kitty protocol's KP_* codes, navigation ones and modifiers included.
    K.notation(Tput::KeyEvent.new(57419, 'u')).should eq "<kUp>"
    K.notation(Tput::KeyEvent.new(57423, 'u')).should eq "<kHome>"
    K.notation(Tput::KeyEvent.new(57426, 'u')).should eq "<kDel>"
    K.notation(Tput::KeyEvent.new(57427, 'u')).should eq "<kOrigin>"
    K.notation(Tput::KeyEvent.new(57414, 'u', Tput::Modifiers::Ctrl)).should eq "<C-kEnter>"
    K.notation(Tput::KeyEvent.new(57414, 'u', type: Tput::KeyEvent::Type::Release)).should be_nil
  end

  it "names a KeyPress of the keypad's Enter <kEnter>, not nothing" do
    ke = Tput::KeyEvent.from_ss3_keypad('M').not_nil!
    e = Crysterm::Event::KeyPress.new ke.char || '\0', ke.to_legacy_key, nil, ke
    K.notation(e).should eq "<kEnter>"
  end
end
