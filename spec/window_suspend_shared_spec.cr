require "./spec_helper"

# A suspend (`Crysterm.suspend`, Ctrl-Z) hands every connected window's
# terminal back and a resume takes it again. Windows sharing one terminal
# (`Window.new(screen: dev)`) pause it once each: the second pause, on a
# terminal already handed back, used to replace the first one's resume with
# one that brought back nothing, so on `fg` the windows drew over the shell's
# screen instead of the alternate one (`Tput#pause` keeps the first).

describe "Crysterm.suspend_terminals on a shared terminal" do
  it "takes the alternate screen back on resume" do
    dev = Crysterm::Screen.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 40, height: 10)
    w1 = Crysterm::Window.new(screen: dev, default_quit_keys: false)
    w2 = Crysterm::Window.new(screen: dev, default_quit_keys: false)
    dev.tput.is_alt.should be_true

    Crysterm.suspend_terminals
    dev.tput.is_alt.should be_false
    Crysterm.resume_terminals
    dev.tput.is_alt.should be_true
  ensure
    w2.try &.destroy
    w1.try &.destroy
  end
end
