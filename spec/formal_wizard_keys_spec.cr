require "./spec_helper"

include Crysterm

# Regression spec for the FORMAL-WIDGETS Wizard fix (live bug B0.4): the Wizard
# had no Enter-to-advance / Escape-to-cancel handling — the modal-dialog
# convention `ColorDialog`/`Question` already follow — so cancel was reachable
# only via the button. The keys are guarded so a focused text editor still gets
# them.

private def mem_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 60, height: 20, default_quit_keys: false)
end

private def three_page_wizard(s)
  wiz = Crysterm::Widget::Wizard.new parent: s, width: 50, height: 16
  wiz.add_page "One", Crysterm::Widget::Box.new(content: "1")
  wiz.add_page "Two", Crysterm::Widget::Box.new(content: "2")
  wiz.add_page "Three", Crysterm::Widget::Box.new(content: "3")
  wiz
end

describe "Wizard Enter/Escape keys (B0.4)" do
  it "Escape cancels the wizard" do
    s = mem_screen
    wiz = three_page_wizard s
    cancelled = false
    wiz.on(Crysterm::Event::Cancelled) { cancelled = true }

    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::Escape)
    cancelled.should be_true
  end

  it "Enter advances pages, then finishes on the last page" do
    s = mem_screen
    wiz = three_page_wizard s
    completed = false
    wiz.on(Crysterm::Event::Completed) { completed = true }

    wiz.current_index.should eq 0
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::Enter)
    wiz.current_index.should eq 1
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::Enter)
    wiz.current_index.should eq 2
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::Enter) # Finish
    completed.should be_true
    wiz.current_index.should eq 2
  end

  it "does not advance on Enter while a text editor on a page is focused" do
    s = mem_screen
    wiz = Crysterm::Widget::Wizard.new parent: s, width: 50, height: 16
    page = Crysterm::Widget::Box.new
    wiz.add_page "Form", page
    wiz.add_page "Two", Crysterm::Widget::Box.new(content: "2")
    le = Crysterm::Widget::LineEdit.new parent: page, top: 0, left: 0, width: 20, height: 1
    s.repaint
    le.focus
    le.focused?.should be_true # sanity: focus actually took

    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::Enter)
    wiz.current_index.should eq 0 # the editor consumed Enter; the wizard stood down
  end

  it "stops intercepting keys after destroy" do
    s = mem_screen
    wiz = three_page_wizard s
    cancelled = 0
    wiz.on(Crysterm::Event::Cancelled) { cancelled += 1 }

    wiz.destroy
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::Escape)
    cancelled.should eq 0 # accelerator was torn down with the widget
  end
end
