require "../../src/crysterm"

alias CT = Crysterm
alias CW = CT::Widgets

# Port of Blessed's test/widget-form.js
#
# Demonstrates `Widget::Form`: Tab/Shift+Tab (and vi_keys j/k) navigation between a
# radio set, text box, checkboxes and submit button, with value collection on submit.
class X
  def initialize
    s = CT::Window.new always_propagated_keys: [::Tput::Key::CtrlQ]

    form = CW::Form.new \
      parent: s,
      keys: true,
      vi_keys: true,
      left: 0,
      top: 0,
      width: "100%",
      height: "100%",
      scrollable: true,
      style: CT::Style.new(bg: "green")

    set = CW::RadioSet.new \
      parent: form,
      left: 1,
      top: 1,
      width: 30,
      height: 1,
      style: CT::Style.new(bg: "magenta")

    CW::RadioButton.new \
      parent: set,
      keys: true,
      height: 1,
      left: 0,
      top: 0,
      name: "radio1",
      content: "radio1",
      style: CT::Style.new(bg: "magenta")

    CW::RadioButton.new \
      parent: set,
      keys: true,
      height: 1,
      left: 15,
      top: 0,
      name: "radio2",
      content: "radio2",
      style: CT::Style.new(bg: "magenta")

    CW::LineEdit.new \
      parent: form,
      keys: true,
      height: 1,
      width: 20,
      left: 1,
      top: 3,
      name: "text",
      style: CT::Style.new(bg: "blue")

    CW::CheckBox.new \
      parent: form,
      keys: true,
      height: 1,
      left: 28,
      top: 1,
      name: "check",
      content: "check",
      style: CT::Style.new(bg: "magenta")

    submit = CW::Button.new \
      parent: form,
      keys: true,
      height: 1,
      width: 8,
      left: 29,
      top: 3,
      shrink_to_fit: true,
      name: "submit",
      content: " submit ",
      align: ::Tput::AlignFlag::Center,
      style: CT::Style.new(bg: "blue")

    output = CW::ScrollableText.new \
      parent: form,
      keys: true,
      left: 0,
      right: 0,
      top: 6,
      height: 6,
      content: "Press Tab/Shift+Tab to move, Enter to edit/toggle, then Submit.",
      style: CT::Style.new(bg: "red")

    submit.on_click do
      form.submit
    end

    form.on(CT::Event::FormSubmitted) do |e|
      lines = e.data.map { |f| "#{f.name}: #{f.value}" }
      output.content = "Submitted:\n" + lines.join("\n")
      s.update
    end

    s.on(CT::Event::KeyPress) do |e|
      if e.char == 'q' || e.key == ::Tput::Key::CtrlQ
        s.destroy
        exit
      end
    end

    form.focus_first

    s.exec
  end
end

X.new
