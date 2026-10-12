require "./spec_helper"

include Crysterm

# The window-management glyphs (`Glyphs::Role::Window*`): one boxed set at the
# Unicode tier, the classic text-UI letters at the ASCII tier, and the close
# button of a torn-off menu and of a `DockWidget` drawn from `WindowClose`.
describe "Glyphs window buttons" do
  it "has a Unicode rendition with an ASCII fallback for each button" do
    {
      Glyphs::Role::WindowClose    => {'x', '⊠'},
      Glyphs::Role::WindowMinimize => {'_', '⊟'},
      Glyphs::Role::WindowMaximize => {'+', '⊞'},
      Glyphs::Role::WindowRestore  => {'=', '❐'},
      Glyphs::Role::WindowRollUp   => {'^', '▴'},
      Glyphs::Role::WindowRollDown => {'v', '▾'},
    }.each do |role, (ascii, unicode)|
      Glyphs[role, Glyphs::Tier::Ascii].should eq ascii
      Glyphs[role, Glyphs::Tier::Unicode].should eq unicode
      Glyphs[role, Glyphs::Tier::Extended].should eq unicode
      role.cell?.should be_false
    end
  end

  {Glyphs::Tier::Unicode => "⊠", Glyphs::Tier::Ascii => "x"}.each do |tier, mark|
    it "draws a DockWidget's close button from WindowClose (#{tier})" do
      s = headless_screen(40, 10)
      s.glyph_tier = tier
      dock = Widget::DockWidget.new parent: s, title: "Dock", width: 20, height: 6
      s.repaint
      dock.titlebar.children.any? { |c| c.content == mark }.should be_true
    end
  end
end
