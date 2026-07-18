# FEATURE: Widget::LogFd — stream a file descriptor / subprocess into a box.
#
# `Crysterm::Widget::LogFd` is the notcurses `ncfdplane` (wrap an `IO`) and
# `ncsubproc` (spawn a command) analogue: a lightweight "just tail this fd into a
# scrolling box" primitive. Text mode only — raw UTF-8 lines are appended and
# autoscrolled; escape sequences are shown literally, not interpreted (use
# `Widget::Terminal` for a real VT). A background reader fiber pumps the source
# and marshals each line onto the render fiber, so the UI never blocks on I/O.
#
# This demo runs two planes side by side: the left spawns a command
# (`ncsubproc`), the right tails a plain in-process pipe we write to ourselves
# (`ncfdplane`). Press q / Ctrl-Q to quit.

require "../../src/crysterm"

include Crysterm

win = Window.new

# Left: spawn a command and stream its stdout+stderr (the `ncsubproc` case).
# A portable shell loop that emits a timestamped line every 0.4s for a while.
left = Widget::LogFd.new(
  "sh", ["-c", "i=0; while [ $i -lt 100 ]; do echo \"tick $i $(date +%H:%M:%S)\"; i=$((i+1)); sleep 0.4; done"],
  parent: win,
  top: 0, left: 0, width: "50%", height: "100%-1",
  max_lines: 500, label: " ncsubproc: sh loop ",
  style: Style.new(border: true))

# Right: tail a plain in-process pipe (the `ncfdplane` case). We own the write
# end and push lines into it from another fiber; LogFd reads the read end.
reader, writer = IO.pipe
right = Widget::LogFd.new(
  io: reader,
  parent: win,
  top: 0, left: "50%", width: "50%", height: "100%-1",
  max_lines: 500, label: " ncfdplane: IO pipe ",
  style: Style.new(border: true))

Widget::Box.new(
  parent: win, bottom: 0, left: 0, height: 1, width: "100%",
  content: "LogFd demo — q to quit",
  style: Style.new(bg: "blue", fg: "white"))

spawn do
  n = 0
  loop do
    sleep 0.3.seconds
    writer.puts "pipe line #{n} — #{Time.local}"
    n += 1
  rescue
    break
  end
end

win.on(Event::KeyPress) do |e|
  if e.char == 'q' || e.key == Tput::Key::CtrlQ
    left.close
    right.close
    writer.close rescue nil
    win.destroy
    exit
  end
end

win.exec
