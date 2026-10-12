require "./spec_helper"

# `Action#name` (Qt's objectName) and finding actions by it
# (`find_action`/`find_actions`, Qt's `findChild<QAction*>`).
describe "Action#name" do
  it "is nil by default and set by name:" do
    Crysterm::Action.new("&Save").name.should be_nil
    Crysterm::Action.new("&Save", name: "save").name.should eq "save"
  end

  it "finds the actions a window's widgets own and present" do
    window = Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new)
    begin
      bar = Crysterm::Widget::MenuBar.new parent: window
      file = bar.add_menu "&File"
      save = file.add_action "&Save", shortcut: "Ctrl+S"
      save.name = "save"
      sub = Crysterm::Widget::Menu.new
      deep = sub.add_action "&Deep"
      deep.name = "deep"
      file.add_action Crysterm::Action.new("&More", menu: [deep])
      box = Crysterm::Widget::Box.new parent: window
      own = Crysterm::Action.new "Own", box, name: "own"
      Crysterm::Action.new "Unnamed", box

      window.find_action("save").should be save
      window.find_action("own").should be own
      window.find_action("missing").should be_nil
      bar.find_action("save").should be save
      box.find_action("save").should be_nil
      window.find_actions("own").should eq [own]
      window.find_actions.compact_map(&.name).should contain "save"
      window.find_actions.count(&.same?(save)).should eq 1
    ensure
      window.destroy
    end
  end
end
