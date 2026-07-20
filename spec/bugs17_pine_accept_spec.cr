require "./spec_helper"

include Crysterm

# Regression spec for BUGS17 B17-21 (src/widget/pine/key_prompt.cr) and
# B17-25 (src/widget/pine/compose.cr) — the same defect class as BUGS16
# B16-39 (see spec/bugs16_question_quit_key_spec.cr): a widget's key handler
# acted on a key but never called `e.accept`, so the same keystroke also fell
# through to the app-global default-quit-key fallback (KeyPrompt) or to
# ancestor/window-level handlers (Compose).

private def pkp_window(w = 40, h = 10)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h)
end

describe "BUGS17 B17-21: Pine::KeyPrompt accepts its handled choice keys" do
  # Window built with the DEFAULT `default_quit_keys` (true, per B17-21's
  # failure scenario) — unlike spec/pine_key_prompt_spec.cr, which sidesteps
  # the interaction entirely by passing `default_quit_keys: false`.
  it "a 'q'-keyed choice answers the prompt and accepts the key" do
    s = pkp_window
    ran = nil.as(String?)
    prompt = Crysterm::Widget::Pine::KeyPrompt.new(
      "Save before leaving?",
      [
        Crysterm::Widget::Pine::KeyPrompt::Choice.new("S", "Save"),
        Crysterm::Widget::Pine::KeyPrompt::Choice.new("Q", "Quit w/o saving", -> { ran = "quit"; nil }),
      ],
      parent: s)
    prompt.focus

    e = Crysterm::Event::KeyPress.new 'q'
    s.emit e

    prompt.answer.should eq "Q"
    ran.should eq "quit"
    e.accepted?.should be_true
  end

  # End-to-end: mirrors bugs16_question_quit_key_spec.cr's "does not let
  # Application.exec_all's quit fallback destroy the window" test. Before the
  # fix, the un-accepted 'q' would also trip the quit fallback and every
  # window would be torn down.
  it "answering with a 'q'-keyed choice does not let the quit fallback destroy the window" do
    s = pkp_window
    prompt = Crysterm::Widget::Pine::KeyPrompt.new(
      "Save before leaving?",
      [
        Crysterm::Widget::Pine::KeyPrompt::Choice.new("S", "Save"),
        Crysterm::Widget::Pine::KeyPrompt::Choice.new("Q", "Quit w/o saving"),
      ],
      parent: s)
    prompt.focus

    spawn { Application.exec_all [s] }
    sleep 20.milliseconds # let exec_all install its own quit-key handler

    s.emit Crysterm::Event::KeyPress.new 'q'
    sleep 30.milliseconds

    prompt.answer.should eq "Q"
    s.destroyed?.should be_false
    s.destroy
  end

  it "still ignores keys that match no choice (nothing accepted, nothing answered)" do
    s = pkp_window
    prompt = Crysterm::Widget::Pine::KeyPrompt.new(
      "Save?",
      [Crysterm::Widget::Pine::KeyPrompt::Choice.new("Y", "Yes")],
      parent: s)
    prompt.focus

    e = Crysterm::Event::KeyPress.new 'z'
    s.emit e

    prompt.answer.should be_nil
    e.accepted?.should be_false
  end
end

private def pc_window
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: 24,
    default_quit_keys: false)
end

describe "BUGS17 B17-25: Pine::Compose field navigation accepts its handled keys" do
  it "Down in a field moves focus to the next field and accepts the key" do
    s = pc_window
    compose = Crysterm::Widget::Pine::Compose.new parent: s, top: 0, bottom: 0, left: 0, width: "100%"
    compose.focus_field "to"

    e = Crysterm::Event::KeyPress.new '\0', Tput::Key::Down
    compose.fields["to"].emit Crysterm::Event::KeyPress, e

    s.focused.should eq compose.fields["cc"]
    e.accepted?.should be_true
  end

  it "Up in a field moves focus to the previous field and accepts the key" do
    s = pc_window
    compose = Crysterm::Widget::Pine::Compose.new parent: s, top: 0, bottom: 0, left: 0, width: "100%"
    compose.focus_field "cc"

    e = Crysterm::Event::KeyPress.new '\0', Tput::Key::Up
    compose.fields["cc"].emit Crysterm::Event::KeyPress, e

    s.focused.should eq compose.fields["to"]
    e.accepted?.should be_true
  end

  it "Up at the top of the body returns to the previous field and accepts the key" do
    s = pc_window
    compose = Crysterm::Widget::Pine::Compose.new parent: s, top: 0, bottom: 0, left: 0, width: "100%"
    compose.body.focus

    e = Crysterm::Event::KeyPress.new '\0', Tput::Key::Up
    compose.body.emit Crysterm::Event::KeyPress, e

    s.focused.should eq compose.fields["subject"]
    e.accepted?.should be_true
  end

  # A key the navigation handler does not act on must stay un-accepted, so
  # typing and other keys still reach the field's own editor.
  it "leaves a non-navigation key un-accepted" do
    s = pc_window
    compose = Crysterm::Widget::Pine::Compose.new parent: s, top: 0, bottom: 0, left: 0, width: "100%"

    e = Crysterm::Event::KeyPress.new '\0', Tput::Key::F1
    compose.fields["to"].emit Crysterm::Event::KeyPress, e

    e.accepted?.should be_false
  end
end
