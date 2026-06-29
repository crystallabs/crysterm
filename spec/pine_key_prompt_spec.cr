require "./spec_helper"

include Crysterm

private def pkp_screen
  Crysterm::Screen.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

private def press(widget, char : Char)
  widget.on_keypress Crysterm::Event::KeyPress.new(char, nil)
end

describe "Pine::KeyPrompt" do
  it "records the answer and runs the choice's callback on a matching key" do
    s = pkp_screen
    ran = nil.as(String?)
    prompt = Crysterm::Widget::Pine::KeyPrompt.new(
      "Save?",
      [
        Crysterm::Widget::Pine::KeyPrompt::Choice.new("Y", "Yes", -> { ran = "yes"; nil }),
        Crysterm::Widget::Pine::KeyPrompt::Choice.new("N", "No"),
      ],
      parent: s)

    press prompt, 'y'
    prompt.answer.should eq "Y"
    ran.should eq "yes"
    prompt.answered_choice.try(&.label).should eq "Yes"
  end

  it "matches keys case-insensitively" do
    s = pkp_screen
    prompt = Crysterm::Widget::Pine::KeyPrompt.new(
      "Pick",
      [Crysterm::Widget::Pine::KeyPrompt::Choice.new("C", "Cancel")],
      parent: s)

    press prompt, 'c'
    prompt.answer.should eq "C"
  end

  it "ignores keys that match no choice" do
    s = pkp_screen
    prompt = Crysterm::Widget::Pine::KeyPrompt.new(
      "Save?",
      [Crysterm::Widget::Pine::KeyPrompt::Choice.new("Y", "Yes")],
      parent: s)

    press prompt, 'z'
    prompt.answer.should be_nil
  end

  it "emits Event::Action with the chosen key" do
    s = pkp_screen
    prompt = Crysterm::Widget::Pine::KeyPrompt.yes_no("Quit?", parent: s)
    got = nil.as(String?)
    prompt.on(Crysterm::Event::Action) { |e| got = e.value }

    press prompt, 'n'
    got.should eq "N"
    prompt.answer.should eq "N"
  end

  # A plain Box does not receive key events; the prompt must register as keyable
  # so the screen actually dispatches the choice keys to it once focused.
  it "is keyable so it receives key presses when focused" do
    s = pkp_screen
    prompt = Crysterm::Widget::Pine::KeyPrompt.yes_no("Quit?", parent: s)
    prompt.keyable?.should be_true
  end

  # Each choice is a clickable child box, so the prompt can be answered with the
  # mouse as well as the keyboard.
  it "answers when a choice box is clicked" do
    s = pkp_screen
    ran = nil.as(String?)
    prompt = Crysterm::Widget::Pine::KeyPrompt.new("Quit?", [
      Crysterm::Widget::Pine::KeyPrompt::Choice.new("Y", "Yes", -> { ran = "yes"; nil }),
      Crysterm::Widget::Pine::KeyPrompt::Choice.new("N", "No", -> { ran = "no"; nil }),
    ], parent: s)
    # cells: [question, Yes, No]
    prompt.cells[2].emit Crysterm::Event::Click
    ran.should eq "no"
    prompt.answer.should eq "N"
  end
end
