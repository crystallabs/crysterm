require "./spec_helper"

include Crysterm

# The `Widget::Dialog` result protocol (Qt's `QDialog`): `#result` / `#done` /
# `#accept` / `#reject`, `Event::Accepted`/`Rejected`/`Finished`, and modality.
#
# Before this, `Dialog`'s entire public surface was `accept`/`cancel` — both
# no-ops — and every subclass invented its own entry point and outcome
# reporting: `ColorDialog`/`DialogButtonBox` emitted `Accepted`/`Rejected` while
# `Question`, `Prompt`, `Message` and `Wizard` emitted neither, and nothing
# carried a result. These pin the protocol down at the base *and* assert that
# each subclass's block-based convenience form (`#ask`, `#read_input`,
# `#display`, `#pick`) now agrees with the signals, so the two can't drift.

private def dr_window
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    default_quit_keys: false)
end

# The minimal concrete dialog: the base class is abstract, so the base-level
# protocol needs a subclass that adds nothing.
private class PlainDialog < Crysterm::Widget::Dialog
end

describe Crysterm::Widget::Dialog do
  describe "result protocol" do
    it "defaults to Rejected, so an unanswered dialog never reads as accepted" do
      d = PlainDialog.new parent: dr_window, width: 20, height: 5
      d.result.should eq Crysterm::Widget::Dialog::Code::Rejected.to_i
      d.accepted?.should be_false
    end

    it "uses Qt's DialogCode numbering" do
      Crysterm::Widget::Dialog::Code::Rejected.to_i.should eq 0
      Crysterm::Widget::Dialog::Code::Accepted.to_i.should eq 1
    end

    it "#accept records the result and emits Accepted then Finished" do
      d = PlainDialog.new parent: dr_window, width: 20, height: 5
      d.show
      log = [] of String
      d.on(Crysterm::Event::Accepted) { log << "accepted" }
      d.on(Crysterm::Event::Rejected) { log << "rejected" }
      d.on(Crysterm::Event::Finished) { |e| log << "finished=#{e.result}" }

      d.accept

      log.should eq ["accepted", "finished=1"]
      d.result.should eq 1
      d.accepted?.should be_true
      d.visible?.should be_false # closing hides it
    end

    it "#reject records the result and emits Rejected then Finished" do
      d = PlainDialog.new parent: dr_window, width: 20, height: 5
      d.show
      log = [] of String
      d.on(Crysterm::Event::Accepted) { log << "accepted" }
      d.on(Crysterm::Event::Rejected) { log << "rejected" }
      d.on(Crysterm::Event::Finished) { |e| log << "finished=#{e.result}" }

      d.reject

      log.should eq ["rejected", "finished=0"]
      d.result.should eq 0
      d.accepted?.should be_false
    end

    it "#done carries an application-defined code on Finished, emitting neither Accepted nor Rejected" do
      d = PlainDialog.new parent: dr_window, width: 20, height: 5
      standard = 0
      finished = nil.as(Int32?)
      d.on(Crysterm::Event::Accepted) { standard += 1 }
      d.on(Crysterm::Event::Rejected) { standard += 1 }
      d.on(Crysterm::Event::Finished) { |e| finished = e.result }

      d.done 7

      d.result.should eq 7
      finished.should eq 7
      standard.should eq 0
    end
  end

  describe "modality" do
    it "#open grabs the window, and closing releases it" do
      w = dr_window
      d = PlainDialog.new parent: w, width: 20, height: 5

      d.modal?.should be_false
      w.grabbing?.should be_false

      d.open
      d.modal?.should be_true
      w.grabbing?.should be_true
      d.visible?.should be_true

      d.accept
      d.modal?.should be_false
      w.grabbing?.should be_false
    end

    it "#destroy releases a modal grab, so it can't outlive the dialog" do
      w = dr_window
      d = PlainDialog.new parent: w, width: 20, height: 5
      d.open
      w.grabbing?.should be_true

      d.destroy

      w.grabbing?.should be_false
    end
  end
end

describe "Dialog subclasses report their outcome" do
  it "Question#ask emits Accepted/Finished alongside its block" do
    w = dr_window
    q = Crysterm::Widget::Question.new parent: w, top: 0, left: 0, width: 40, height: 8
    answer = nil.as(Bool?)
    log = [] of String
    q.on(Crysterm::Event::Accepted) { log << "accepted" }
    q.on(Crysterm::Event::Finished) { |e| log << "finished=#{e.result}" }
    q.ask("Sure?") { |_err, data| answer = data }

    w.emit Crysterm::Event::KeyPress.new('\r', ::Tput::Key::Enter)

    answer.should be_true
    log.should eq ["accepted", "finished=1"]
    q.result.should eq 1
  end

  it "Question#ask emits Rejected/Finished on a negative answer" do
    w = dr_window
    q = Crysterm::Widget::Question.new parent: w, top: 0, left: 0, width: 40, height: 8
    log = [] of String
    q.on(Crysterm::Event::Rejected) { log << "rejected" }
    q.on(Crysterm::Event::Finished) { |e| log << "finished=#{e.result}" }
    q.ask("Sure?") { }

    w.emit Crysterm::Event::KeyPress.new('\0', ::Tput::Key::Escape)

    log.should eq ["rejected", "finished=0"]
    q.result.should eq 0
  end

  it "Prompt#read_input reports Accepted with the submitted value" do
    w = dr_window
    p = Crysterm::Widget::Prompt.new parent: w, top: 0, left: 0, width: 40, height: 8
    value = nil.as(String?)
    finished = nil.as(Int32?)
    p.on(Crysterm::Event::Finished) { |e| finished = e.result }
    p.read_input("Name?") { |_err, data| value = data }

    # `#accept` submits the embedded field rather than closing behind its back,
    # so the typed text still reaches the callback.
    p.textinput.value = "crystal"
    p.accept

    value.should eq "crystal"
    finished.should eq 1
    p.result.should eq 1
  end

  it "Prompt#reject reports Rejected and a nil value" do
    w = dr_window
    p = Crysterm::Widget::Prompt.new parent: w, top: 0, left: 0, width: 40, height: 8
    called = false
    value = "unset".as(String?)
    p.on(Crysterm::Event::Rejected) { called = true }
    p.read_input("Name?") { |_err, data| value = data }

    p.reject

    called.should be_true
    value.should be_nil
    p.result.should eq 0
  end

  it "Message reports Accepted once dismissed, and #accept runs the display callback" do
    w = dr_window
    m = Crysterm::Widget::Message.new parent: w, top: 0, left: 0, width: 40, height: 5
    ran = false
    finished = nil.as(Int32?)
    m.on(Crysterm::Event::Finished) { |e| finished = e.result }
    # No timeout: normally dismissed by the next keypress. `#accept` must take
    # the same path (callback + result), not close behind `#display`'s back.
    m.display("hi", nil) { ran = true }

    m.accept

    ran.should be_true
    finished.should eq 1
    m.result.should eq 1
    m.visible?.should be_false
  end

  it "ColorDialog#pick reports Accepted after Action, and Rejected on cancel" do
    w = dr_window
    cd = Crysterm::Widget::ColorDialog.new parent: w, top: 0, left: 0, width: 56, height: 20
    cd.current_color = "#0000ff"
    log = [] of String
    cd.on(Crysterm::Event::Action) { |e| log << "action=#{e.value}" }
    cd.on(Crysterm::Event::Accepted) { log << "accepted" }
    cd.on(Crysterm::Event::Finished) { |e| log << "finished=#{e.result}" }
    cd.pick { }

    cd.accept

    # The chosen value goes out before the outcome.
    log.should eq ["action=#0000ff", "accepted", "finished=1"]
    cd.result.should eq 1
  end

  it "Wizard Finish accepts, Cancel rejects — and Enter still advances rather than accepting" do
    w = dr_window
    wiz = Crysterm::Widget::Wizard.new parent: w, width: 50, height: 16
    wiz.add_page Crysterm::Widget::Box.new, title: "One"
    wiz.add_page Crysterm::Widget::Box.new, title: "Two"
    log = [] of String
    wiz.on(Crysterm::Event::Complete) { log << "complete" }
    wiz.on(Crysterm::Event::Accepted) { log << "accepted" }
    wiz.on(Crysterm::Event::Finished) { |e| log << "finished=#{e.result}" }

    # Enter on a non-last page advances; it must NOT accept (the old
    # `Wizard#accept = advance` override broke that contract the other way).
    w.emit Crysterm::Event::KeyPress.new('\r', ::Tput::Key::Enter)
    wiz.current_index.should eq 1
    log.empty?.should be_true

    # Enter on the last page finishes: Complete, then the standard acceptance.
    w.emit Crysterm::Event::KeyPress.new('\r', ::Tput::Key::Enter)
    log.should eq ["complete", "accepted", "finished=1"]
    wiz.result.should eq 1
  end

  it "Wizard#reject emits Cancel on top of the standard rejection" do
    w = dr_window
    wiz = Crysterm::Widget::Wizard.new parent: w, width: 50, height: 16
    wiz.add_page Crysterm::Widget::Box.new, title: "One"
    log = [] of String
    wiz.on(Crysterm::Event::Cancel) { log << "cancel" }
    wiz.on(Crysterm::Event::Rejected) { log << "rejected" }
    wiz.on(Crysterm::Event::Finished) { |e| log << "finished=#{e.result}" }

    wiz.reject

    log.should eq ["cancel", "rejected", "finished=0"]
    wiz.result.should eq 0
  end
end

describe Crysterm::Widget::DialogButtonBox do
  it "labels the Ok button 'OK' (Qt's label), not 'Okay'" do
    text, role = Crysterm::Widget::DialogButtonBox.descriptor_for(
      Crysterm::Widget::DialogButtonBox::StandardButton::Ok)
    text.should eq "OK"
    role.should eq Crysterm::Widget::DialogButtonBox::Role::Accept
  end

  it "emits box-level ButtonClick for every button, whatever its role" do
    w = dr_window
    bb = Crysterm::Widget::DialogButtonBox.new parent: w,
      buttons: Crysterm::Widget::DialogButtonBox::StandardButton::Ok |
               Crysterm::Widget::DialogButtonBox::StandardButton::Help
    clicked = [] of Crysterm::Widget::DialogButtonBox::StandardButton?
    bb.on(Crysterm::Event::ButtonClick) { |e| clicked << bb.standard_button(e.button.as(Crysterm::Widget::Button)) }

    bb.button(Crysterm::Widget::DialogButtonBox::StandardButton::Ok).not_nil!.emit Crysterm::Event::Press
    # Help carries no accept/reject meaning, but still reports the click.
    bb.button(Crysterm::Widget::DialogButtonBox::StandardButton::Help).not_nil!.emit Crysterm::Event::Press

    clicked.should eq [
      Crysterm::Widget::DialogButtonBox::StandardButton::Ok,
      Crysterm::Widget::DialogButtonBox::StandardButton::Help,
    ]
  end

  it "#standard_button returns nil for a custom button" do
    w = dr_window
    bb = Crysterm::Widget::DialogButtonBox.new parent: w,
      buttons: Crysterm::Widget::DialogButtonBox::StandardButton::Ok
    custom = bb.add_button "Custom"
    bb.standard_button(custom).should be_nil
  end

  it "#standard_buttons= rebuilds the row after construction" do
    w = dr_window
    bb = Crysterm::Widget::DialogButtonBox.new parent: w,
      buttons: Crysterm::Widget::DialogButtonBox::StandardButton::Ok
    bb.buttons.size.should eq 1

    bb.standard_buttons = Crysterm::Widget::DialogButtonBox::StandardButton::Yes |
                          Crysterm::Widget::DialogButtonBox::StandardButton::No

    bb.buttons.size.should eq 2
    bb.button(Crysterm::Widget::DialogButtonBox::StandardButton::Ok).should be_nil
    bb.button(Crysterm::Widget::DialogButtonBox::StandardButton::Yes).should_not be_nil
    bb.standard_buttons.should eq(
      Crysterm::Widget::DialogButtonBox::StandardButton::Yes |
      Crysterm::Widget::DialogButtonBox::StandardButton::No)
  end
end

describe Crysterm::ActionGroup do
  it "keeps at most one member checked (the QActionGroup contract)" do
    g = Crysterm::ActionGroup.new
    a = Crysterm::Action.new "Icons"
    b = Crysterm::Action.new "List"
    c = Crysterm::Action.new "Details"
    g << a << b << c

    # An exclusive group makes its members checkable on add, as Qt does.
    a.checkable?.should be_true

    a.trigger
    g.checked_action.should eq a

    b.trigger
    g.checked_action.should eq b
    a.checked?.should be_false

    # Programmatic checking is exclusive too, not just activation.
    c.checked = true
    g.checked_action.should eq c
    b.checked?.should be_false
  end

  it "relays a member's activation as the group's own Triggered" do
    g = Crysterm::ActionGroup.new
    a = Crysterm::Action.new "Icons"
    g << a
    seen = 0
    g.on(Crysterm::Event::Triggered) { |e| seen += 1 if e.checked }

    a.trigger

    seen.should eq 1
  end

  it "a non-exclusive group lets several members be checked" do
    g = Crysterm::ActionGroup.new exclusive: false
    a = Crysterm::Action.new "Bold", checkable: true
    b = Crysterm::Action.new "Italic", checkable: true
    g << a << b

    a.checked = true
    b.checked = true

    a.checked?.should be_true
    b.checked?.should be_true
  end

  it "#enabled=/#visible= push onto every member" do
    g = Crysterm::ActionGroup.new
    a = Crysterm::Action.new "Icons"
    b = Crysterm::Action.new "List"
    g << a << b

    g.enabled = false
    a.enabled?.should be_false
    b.enabled?.should be_false
    g.enabled?.should be_false

    g.visible = false
    a.visible?.should be_false
    g.visible?.should be_false
  end

  it "#remove_action drops the group's handlers, leaving the action intact" do
    g = Crysterm::ActionGroup.new
    a = Crysterm::Action.new "Icons"
    b = Crysterm::Action.new "List"
    g << a << b
    a.checked = true

    g.remove_action a
    b.checked = true

    # `a` is no longer a member, so exclusivity must not reach it.
    a.checked?.should be_true
    g.actions.should eq [b]
  end
end
