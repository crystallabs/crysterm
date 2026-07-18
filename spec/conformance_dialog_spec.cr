require "./spec_helper"

include Crysterm

# FORMAL-WIDGETS Part B / B8 — shared behavioral conformance for the modal dialog
# family (`ColorDialog`, `Question`, `Prompt`, `Wizard`). The dialogs are
# deliberately heterogeneous (some deliver results via emitted events, some via
# block callbacks; the accept/cancel gesture is a window-level Enter/Escape for
# most but the embedded field's submit/cancel for `Prompt`), so the adapter's
# `accept`/`cancel` closures encapsulate each one's canonical gesture and the
# script asserts the *outcome*: an accept path and a cancel path both exist and
# fire. Focus save/restore is a capability flag — `Wizard` intentionally does not
# save/restore focus, so that example is only run for the three that do. Would
# have caught the B0.4 drift (Wizard had no Escape-to-cancel at all).

private def dlg_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new, default_quit_keys: false)
end

private record DialogHandle,
  accept : Proc(Nil),
  cancel : Proc(Nil),
  accepted : Proc(Bool),
  cancelled : Proc(Bool),
  focus_restored : Proc(Bool)?

private def it_behaves_like_a_modal_dialog(name : String, saves_focus : Bool, &make : -> DialogHandle)
  describe name do
    it "runs the accept path on its accept gesture" do
      h = make.call
      h.accept.call
      h.accepted.call.should be_true
    end

    it "runs the cancel path on its cancel gesture" do
      h = make.call
      h.cancel.call
      h.cancelled.call.should be_true
    end

    if saves_focus
      it "restores the previously focused widget on close" do
        h = make.call
        h.cancel.call
        h.focus_restored.not_nil!.call.should be_true
      end
    end
  end
end

private def enter_key
  Crysterm::Event::KeyPress.new '\r', ::Tput::Key::Enter
end

private def escape_key
  Crysterm::Event::KeyPress.new '\0', ::Tput::Key::Escape
end

describe "Modal dialog conformance (B8)" do
  it_behaves_like_a_modal_dialog "ColorDialog", saves_focus: true do
    s = dlg_screen
    victim = Crysterm::Widget::Box.new parent: s
    s.focus victim
    cd = Crysterm::Widget::ColorDialog.new parent: s, width: 50, height: 18
    accepted = false
    cancelled = false
    cd.get_color { |color| color ? (accepted = true) : (cancelled = true) }
    DialogHandle.new(
      accept: -> { s.emit enter_key; nil },
      cancel: -> { s.emit escape_key; nil },
      accepted: -> { accepted },
      cancelled: -> { cancelled },
      focus_restored: -> { s.focused == victim },
    )
  end

  it_behaves_like_a_modal_dialog "Question", saves_focus: true do
    s = dlg_screen
    victim = Crysterm::Widget::Box.new parent: s
    s.focus victim
    q = Crysterm::Widget::Question.new parent: s, top: 0, left: 0, width: 40, height: 8
    accepted = false
    cancelled = false
    q.ask("Sure?") { |data| data ? (accepted = true) : (cancelled = true) }
    DialogHandle.new(
      accept: -> { s.emit enter_key; nil },
      cancel: -> { s.emit escape_key; nil },
      accepted: -> { accepted },
      cancelled: -> { cancelled },
      focus_restored: -> { s.focused == victim },
    )
  end

  it_behaves_like_a_modal_dialog "Prompt", saves_focus: true do
    s = dlg_screen
    victim = Crysterm::Widget::Box.new parent: s
    s.focus victim
    pr = Crysterm::Widget::Prompt.new parent: s, top: 0, left: 0, width: 40, height: 8
    accepted = false
    cancelled = false
    pr.read_input("Name?") { |data| data ? (accepted = true) : (cancelled = true) }
    DialogHandle.new(
      # Prompt has no window-level accelerator: Enter/Escape are the embedded
      # LineEdit's submit/cancel (which is what accept/cancel resolve to).
      accept: -> { pr.line_edit.value = "x"; pr.line_edit.submit; nil },
      cancel: -> { pr.line_edit.cancel; nil },
      accepted: -> { accepted },
      cancelled: -> { cancelled },
      focus_restored: -> { s.focused == victim },
    )
  end

  it_behaves_like_a_modal_dialog "Wizard", saves_focus: false do
    s = dlg_screen
    wiz = Crysterm::Widget::Wizard.new parent: s, width: 50, height: 16
    wiz.add_page Crysterm::Widget::Box.new, title: "One"
    accepted = false
    cancelled = false
    wiz.on(Crysterm::Event::Completed) { accepted = true }
    wiz.on(Crysterm::Event::Cancelled) { cancelled = true }
    DialogHandle.new(
      # Single page → Enter finishes (Complete); Escape cancels.
      accept: -> { s.emit enter_key; nil },
      cancel: -> { s.emit escape_key; nil },
      accepted: -> { accepted },
      cancelled: -> { cancelled },
      focus_restored: nil,
    )
  end
end
