require "./spec_helper"

# `Neovim::Handler#attach` answers whether the handler is attached when it
# returns: a Neovim that ends while the attach is still setting it up (here
# at the first state the handler asks it for, the last step) leaves the
# widget on its own, and the attach says false.

# Neovim's arguments for one that quits when the handler first asks for its
# state: the handler's Lua table made in advance, its `state` replaced.
private QUIT_AT_STATE = "lua _G.crysterm_vi = setmetatable({ quiet = {} }, { __newindex = function(t, k, v) " \
                        "if k == 'state' then v = function() vim.cmd('qall!') end end rawset(t, k, v) end })"

describe Crysterm::Neovim::Handler do
  unless Crysterm::Neovim.available?
    pending "needs nvim in PATH"
    next
  end

  it "returns false from an attach whose Neovim ends during it" do
    window = Crysterm::Window.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 40, height: 10, default_quit_keys: false)
    w = Crysterm::Widget::PlainTextEdit.new parent: window, width: 40, height: 8
    w.value = "abc"
    h = Crysterm::Neovim::Handler.new args: Crysterm::Neovim::Handler.default_args + ["--cmd", QUIT_AT_STATE]
    h.attach(w).should be_false
    h.attached?.should be_false
    w.value.should eq "abc"
  ensure
    window.try &.destroy
  end
end
