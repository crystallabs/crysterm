require "./spec_helper"

include Crysterm

# Regression specs for BUGS13 core findings C1, C5, C10, C19, C23, C24
# (src/application.cr, src/window.cr, src/window_connection.cr):
#
# C1  — `Application.exec_all`'s quit handler must honor `accepted?` and
#       `grab_keys?` (like `#route_input` does), so `q` typed into a widget
#       that consumed it doesn't close every window.
# C5  — `Application#activate` must re-emit the raised window's whole frame:
#       the draw diff runs against the window's PRIVATE `@olines`, while the
#       terminal may be showing a sibling, so an "unchanged" frame emitted
#       zero bytes and the raise was invisible.
# C10 — `exec_all` must return when the managed windows are destroyed
#       *programmatically* (`w.destroy`), not only via the quit key/close.
# C19 — cursor shape/color are per-window but pushed to a shared device only
#       from `apply_cursor`; `activate` and the disconnect-with-surviving-
#       sibling path must re-assert the active window's cursor.
# C24 — same gap for the OSC title; also `title = nil` must actually clear a
#       previously-set title on the terminal.
# C23 — the clipboard facade must be routable to the *requesting* window's
#       device instead of always the app-active window's; the consumer path
#       (`Mixin::TextEditing#copy_selection`) passes the widget's own window.
# C14 — a terminal resize on a shared device must not re-stack the windows in
#       creation order: only the device-active window repaints (a non-active
#       sibling reallocs without rendering), so the activated window stays on
#       top.

private def b13_window(w = 40, h = 10)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

private def b13_shared_screen(w = 40, h = 10)
  Crysterm::Screen.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h)
end

private def wait_until(timeout = 2.seconds, &)
  deadline = Time.instant + timeout
  until yield
    raise "wait_until: condition not met within #{timeout}" if Time.instant > deadline
    sleep 2.milliseconds
  end
end

describe "BUGS13 C1: exec_all quit honors accepted?/grab_keys" do
  it "does not quit on an accepted key, or while keys are grabbed; quits on a plain q" do
    w = b13_window
    finished = false
    spawn do
      Application.exec_all [w]
      finished = true
    end
    sleep 20.milliseconds # let exec_all install its handlers

    # A widget consumed the `q` (e.g. typing into a text field): no quit.
    e = Crysterm::Event::KeyPress.new 'q'
    e.accept
    w.emit Crysterm::Event::KeyPress, e
    sleep 30.milliseconds
    w.destroyed?.should be_false
    finished.should be_false

    # Keyboard grabbed: no quit either.
    w.grab_keys = true
    w.emit Crysterm::Event::KeyPress, Crysterm::Event::KeyPress.new('q')
    sleep 30.milliseconds
    w.destroyed?.should be_false
    w.grab_keys = false

    # A plain, un-accepted `q` still quits gracefully.
    w.emit Crysterm::Event::KeyPress, Crysterm::Event::KeyPress.new('q')
    wait_until { w.destroyed? }
    wait_until { finished }
  end
end

describe "BUGS13 C10: exec_all returns on programmatic destroy" do
  it "unblocks once every managed window is destroyed directly" do
    w1 = b13_window
    w2 = b13_window
    finished = false
    spawn do
      Application.exec_all [w1, w2]
      finished = true
    end
    sleep 20.milliseconds

    # The standard close API, never routed through the quit key or a
    # WindowClosed: used to leave `remaining` pinned above zero forever.
    w1.destroy
    sleep 30.milliseconds
    finished.should be_false # one window still alive
    w2.destroy
    wait_until { finished }
  end

  it "counts a window only once even when it closes via quit after a destroy" do
    w1 = b13_window
    w2 = b13_window
    finished = false
    spawn do
      Application.exec_all [w1, w2]
      finished = true
    end
    sleep 20.milliseconds

    w1.destroy
    # The quit key now tears down the remaining windows; w1 must not be
    # double-counted (which would fire `done` before w2 actually went).
    w2.emit Crysterm::Event::KeyPress, Crysterm::Event::KeyPress.new('q')
    wait_until { finished }
    w1.destroyed?.should be_true
    w2.destroyed?.should be_true
  end
end

describe "BUGS13 C5: activate re-emits the raised window's frame" do
  it "re-sends the window content even when its own frame is unchanged" do
    w = b13_window
    Widget::Box.new parent: w, left: 0, top: 0, width: 10, height: 1, content: "HELLO13"
    app = Application.new
    app.add w

    w._render
    out = w.output.as(IO::Memory)
    out.clear

    # Unchanged frame: the plain diff emits nothing (the pre-fix behavior of
    # activate) — this is the control.
    w._render
    out.to_s.includes?("HELLO13").should be_false

    # activate must invalidate + repaint, so the content is re-emitted even
    # though this window's private @olines already matches it.
    app.activate w
    wait_until { out.to_s.includes? "HELLO13" }

    w.destroy
  end
end

describe "BUGS13 C19/C24: per-window cursor/title re-asserted on a shared device" do
  it "activate re-applies the activated window's cursor and title" do
    s = b13_shared_screen
    a = Window.new(screen: s, default_quit_keys: false)
    b = Window.new(screen: s, default_quit_keys: false)
    app = Application.new
    app.add a
    app.add b

    a.title = "WIN-A"
    out = s.output.as(IO::Memory)
    a.cursor._set = false
    out.clear

    app.activate a
    # apply_cursor ran for the raised window...
    a.cursor._set.should be_true
    # ...and its title was re-pushed to the shared terminal.
    out.to_s.includes?("\e]0;WIN-A\a").should be_true

    a.destroy
    b.destroy
  end

  it "destroying a sibling re-applies the surviving window's cursor and title" do
    s = b13_shared_screen
    a = Window.new(screen: s, default_quit_keys: false)
    b = Window.new(screen: s, default_quit_keys: false)
    app = Application.new
    app.add a
    app.add b

    a.title = "KEEP"
    out = s.output.as(IO::Memory)
    a.cursor._set = false
    out.clear

    # b departs the shared device; its pinned cursor/title must not outlive it.
    b.destroy
    a.cursor._set.should be_true
    out.to_s.includes?("\e]0;KEEP\a").should be_true

    a.destroy
  end

  it "title = nil clears a previously-set title on the terminal" do
    w = b13_window
    w.title = "GONE-SOON"
    out = w.output.as(IO::Memory)
    out.clear

    w.title = nil
    # An empty OSC 0 title is emitted (previously only the ivar was nil'ed and
    # the terminal kept showing the stale title forever).
    out.to_s.includes?("\e]0;\a").should be_true

    w.destroy
  end
end

describe "BUGS13 C23: clipboard routes to the requesting window's device" do
  it "set_text writes OSC-52 to the given window, not the app-active one" do
    app = Application.new
    w1 = b13_window
    w2 = b13_window
    app.add w1
    app.add w2 # active_window == w2

    o1 = w1.output.as(IO::Memory)
    o2 = w2.output.as(IO::Memory)
    o1.clear
    o2.clear

    app.clipboard.set_text "SECRET", window: w1
    o1.size.should be > 0
    o2.size.should eq 0
    app.clipboard.text.should eq "SECRET"

    # Unspecified window keeps the app-active default.
    o1.clear
    app.clipboard.text = "OTHER"
    o2.size.should be > 0
    o1.size.should eq 0

    w1.destroy
    w2.destroy
  end

  it "request queries the given window's device" do
    app = Application.new
    w1 = b13_window
    w2 = b13_window
    app.add w1
    app.add w2

    o1 = w1.output.as(IO::Memory)
    o2 = w2.output.as(IO::Memory)
    o1.clear
    o2.clear

    app.clipboard.request window: w1
    o1.size.should be > 0
    o2.size.should eq 0

    w1.destroy
    w2.destroy
  end

  it "copy_selection emits OSC-52 on the copying widget's own device" do
    app = Application.new
    w1 = b13_window 60, 15
    w2 = b13_window 60, 15
    app.add w1
    app.add w2 # active_window == w2 — NOT the window hosting the widget

    begin
      te = Widget::TextEdit.new parent: w1, left: 0, top: 0, width: 30, height: 5,
        content: "hello"
      w1._render
      # Select "hello" the way the mouse path does.
      te.cursor_pos = 5
      te.selection_anchor = 0

      o1 = w1.output.as(IO::Memory)
      o2 = w2.output.as(IO::Memory)
      o1.clear
      o2.clear

      # Ctrl-C → copy_selection → buf_copy_to_clipboard(..., window?) →
      # Clipboard#set_text(value, window): the OSC-52 write lands on the
      # widget's OWN terminal, not the app-active window's.
      te._listener Crysterm::Event::KeyPress.new('\0', ::Tput::Key::CtrlC)

      osc52 = Base64.strict_encode "hello"
      o1.to_s.includes?(osc52).should be_true
      o2.to_s.includes?(osc52).should be_false
      # The in-process mirror stays app-wide.
      app.clipboard.text.should eq "hello"
    ensure
      w1.destroy
      w2.destroy
    end
  end
end

describe "BUGS13 C14: resize repaints only the device-active window" do
  it "keeps the activated window on top after a shared-device resize" do
    # An UNPINNED shared device (no explicit width/height), so a resize can
    # genuinely change the size (a pinned axis ignores the report).
    s = Crysterm::Screen.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
    a = Window.new(screen: s, default_quit_keys: false)
    b = Window.new(screen: s, default_quit_keys: false)
    begin
      Widget::Box.new parent: a, left: 0, top: 0, width: 10, height: 1, content: "AAA14"
      Widget::Box.new parent: b, left: 0, top: 0, width: 10, height: 1, content: "BBB14"
      app = Application.new
      app.add a
      app.add b # creation order: a first, b last

      out = s.output.as(IO::Memory)
      # Raise the FIRST-created window; wait for its repaint to land, then
      # settle so no scheduled render bleeds into the assertions below.
      app.activate a
      wait_until { out.to_s.includes? "AAA14" }
      sleep 80.milliseconds
      out.clear

      size = ::Tput::Namespace::Size.new(a.awidth - 5, a.aheight - 2)

      # The resize reaches every window on the device; creation order would
      # repaint b LAST (dropping the activated a behind it). Post-fix a
      # non-active window only reallocs — it must emit nothing.
      b.emit ::Crysterm::Event::Resize.new size
      sleep 80.milliseconds
      out.to_s.includes?("BBB14").should be_false

      # The device-active window does repaint, so the raise survives the resize.
      a.emit ::Crysterm::Event::Resize.new size
      wait_until { out.to_s.includes? "AAA14" }
      out.to_s.includes?("BBB14").should be_false
    ensure
      a.destroy
      b.destroy
    end
  end
end
