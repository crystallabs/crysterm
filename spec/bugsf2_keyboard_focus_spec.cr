require "./spec_helper"

include Crysterm

# Regression specs for the BUGS-F2 keyboard / focus findings:
#
#  #1  — The default quit hotkey (`q`/Ctrl-Q) must be a *fallback*, not fire in
#        `Application#route_input` BEFORE the window/widgets see the key (which
#        made typing `q` into a reading `LineEdit`/`TextEdit` exit the app):
#        the window handles the key first and quit only fires when it comes
#        back un-`accepted?` and no widget grabbed keys.
#  #4  — A text-edit teardown must not run `restore_focus` when the user
#        deliberately Tab'd/clicked to another widget — that yanks focus back
#        to the pre-read widget. Gated the same way as the rewind
#        (`@_skip_rewind`).
#  #7  — Text editors must `#accept` the keys they consume (printable insert,
#        movement, Backspace/Delete, Enter/Escape) so window-level accelerators
#        don't double-act on typed characters, and leave keys they ignore (Tab)
#        un-accepted.
#  #26 — `restore_focus` must guard on `!sf.disabled?`, not re-focus a widget
#        disabled while a dialog was open (silently re-enabling it).
#  #27 — `rewind_focus`'s empty-history branch must mirror `_focus`'s
#        `if o.state.focused?` guard, not reset the popped widget's state
#        unconditionally.
#  #35 — An external `value=` must clear `@goal_col` (stale, it makes the next
#        Up/Down jump to an old column); the redisplay/`nil` branch of
#        `assign_value` keeps it.

private def f2_screen(default_quit_keys = false)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: 24, default_quit_keys: default_quit_keys)
end

private def f2_key(char : Char, k : ::Tput::Key? = nil)
  Crysterm::Event::KeyPress.new char, k
end

private def f2_ctl(k : ::Tput::Key)
  Crysterm::Event::KeyPress.new '\0', k
end

# Expose the protected/private editor internals under test.
class Crysterm::Widget::PlainTextEdit
  def goal_col
    @goal_col
  end

  def goal_col=(v)
    @goal_col = v
  end
end

describe "BUGS-F2 #1 default quit keys are a fallback, not a pre-empt" do
  it "does NOT quit while a LineEdit is reading — the char is edited instead" do
    app = Crysterm::Application.new
    win = f2_screen(default_quit_keys: true)
    app.add win

    le = Widget::LineEdit.new parent: win, left: 0, top: 0, width: 40, height: 1, content: ""
    win.repaint
    le.read_input
    win.grab_keys?.should be_true

    # A pre-empting quit would exit the process (`win.destroy; exit`) before the
    # widget ever saw the key — reaching the assertion at all proves no quit fired.
    app.route_input win.screen, ::Tput::InputEvent.new('q')

    le.value.should eq "q"
    win.grab_keys?.should be_true
  end

  it "does NOT quit when a window handler #accepts the quit key" do
    app = Crysterm::Application.new
    win = f2_screen(default_quit_keys: true)
    app.add win

    seen = false
    win.on(Crysterm::Event::KeyPress) do |e|
      seen = true
      e.accept if e.char == 'q'
    end

    app.route_input win.screen, ::Tput::InputEvent.new('q')

    seen.should be_true # handler ran and the process is still alive
  end
end

describe "BUGS-F2 #7 a reading editor accepts the keys it consumes" do
  it "accepts printable insertions, editing and Enter/Escape but not Tab" do
    win = f2_screen
    le = Widget::LineEdit.new parent: win, left: 0, top: 0, width: 40, height: 1, content: ""
    win.repaint

    ins = f2_key('a')
    le._listener ins
    ins.accepted?.should be_true
    le.value.should eq "a"

    bs = f2_ctl(::Tput::Key::Backspace)
    le._listener bs
    bs.accepted?.should be_true

    esc = f2_ctl(::Tput::Key::Escape)
    le._listener esc
    esc.accepted?.should be_true

    left = f2_ctl(::Tput::Key::Left)
    le._listener left
    left.accepted?.should be_true

    # Tab is left un-accepted so window Tab-navigation still works.
    tab = f2_ctl(::Tput::Key::Tab)
    le._listener tab
    tab.accepted?.should be_false
  end
end

describe "BUGS-F2 #4 text-edit teardown does not yank focus when focus moved on" do
  it "leaves focus on the tabbed-to widget instead of restoring the pre-read one" do
    win = f2_screen
    a = Widget::Box.new parent: win, left: 0, top: 0, width: 10, height: 1
    le = Widget::LineEdit.new parent: win, left: 0, top: 2, width: 40, height: 1, content: ""
    b = Widget::Box.new parent: win, left: 0, top: 4, width: 10, height: 1
    win.repaint

    win.focus a
    le.read_input # saves `a` (le was unfocused), focuses le
    win.saved_focus.should be(a)

    win.focus b # blur le -> teardown with @_skip_rewind = true

    win.focused.should be(b) # restore_focus must not yank it back to `a`
    win.saved_focus.should be_nil
  end
end

describe "BUGS-F2 #26 restore_focus skips a widget disabled while saved" do
  it "does not re-focus (and thus re-enable) a disabled saved widget" do
    win = f2_screen
    a = Widget::Box.new parent: win, left: 0, top: 0, width: 10, height: 1
    b = Widget::Box.new parent: win, left: 0, top: 2, width: 10, height: 1
    win.repaint

    win.focus a
    win.save_focus      # dialog opens, remembers `a`
    win.focus b         # dialog focuses its own widget
    a.state = :disabled # app disables `a` while the dialog is open

    win.restore_focus # dialog closes

    win.focused.should be(b)   # not yanked back to `a`
    a.disabled?.should be_true # state not clobbered back to Focused
  end
end

describe "BUGS-F2 #27 rewind_focus empty-history branch guards on focused?" do
  it "does not reset (re-enable) a popped widget that is not focused" do
    win = f2_screen
    a = Widget::Box.new parent: win, left: 0, top: 0, width: 10, height: 1
    win.repaint

    win.focus a
    a.state = :disabled # disabled while focused

    blurred = false
    a.on(Crysterm::Event::FocusOut) { blurred = true }

    win.rewind_focus # only entry -> empty-history branch

    a.state.disabled?.should be_true # not reset to Normal
    blurred.should be_false          # no spurious Blur for an unfocused widget
  end
end

describe "BUGS-F2 #35 external value= clears the vertical goal column" do
  it "clears @goal_col on an external set but keeps it on redisplay" do
    win = f2_screen
    pte = Widget::PlainTextEdit.new parent: win, left: 0, top: 0, width: 40, height: 6, content: "hello"
    win.repaint

    pte.goal_col = 50
    pte.value = "brand new text"
    pte.goal_col.should be_nil # not left stale

    # The redisplay path (nil value, e.g. from #render) must NOT clear it.
    pte.goal_col = 42
    pte.refresh_value
    pte.goal_col.should eq 42
  end
end
