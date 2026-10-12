require "./spec_helper"

# The window's title on the terminal: sent once the window has taken the
# terminal over (after the alternate screen's `smcup`, which may save the
# title itself), with the terminal's own title saved first (`CSI 22 ; 0 t`)
# and put back when the window hands the terminal back (`CSI 23 ; 0 t`,
# before `rmcup`), on destroy and while suspended.

private def titled_window(title : String?)
  output = IO::Memory.new
  window = Crysterm::Window.new(input: IO::Memory.new, output: output, error: IO::Memory.new,
    width: 40, height: 10, title: title, default_quit_keys: false)
  {window, output}
end

describe "Crysterm::Window title" do
  it "sends the title after taking the terminal over, the terminal's own saved first" do
    window, output = titled_window "doc.md • MD"
    window.tput.flush
    out = output.to_s
    push = out.index!("\e[22;0t")
    title = out.index!("\e]0;doc.md • MD\a")
    alt = out.index("\e[?1049h") || out.index("\e[?47h")
    alt.try { |a| a.should be < push }
    push.should be < title
    out.scan("\e]0;").size.should eq 1
    window.destroy
  end

  it "saves the terminal's title once across changes, and puts it back on destroy" do
    window, output = titled_window "a • MD"
    window.title = "b • MD"
    window.title = "c • MD"
    window.tput.flush
    output.to_s.scan("\e[22;0t").size.should eq 1
    output.to_s.should contain "\e]0;c • MD\a"
    output.clear
    window.destroy
    out = output.to_s
    restore = out.index!("\e[23;0t")
    normal = out.index("\e[?1049l") || out.index("\e[?47l")
    normal.try { |n| restore.should be < n }
  end

  it "saves and restores nothing for a window that never had a title" do
    window, output = titled_window nil
    window.destroy
    output.to_s.should_not contain "\e[22;0t"
    output.to_s.should_not contain "\e[23;0t"
  end

  it "gives the terminal's title back while suspended and the window's on resume" do
    window, output = titled_window "doc.md • MD"
    window.tput.flush
    output.clear
    window.tput.pause
    window.tput.flush
    output.to_s.should contain "\e[23;0t"
    output.clear
    window.tput.resume
    window.tput.flush
    output.to_s.should contain "\e[22;0t\e]0;doc.md • MD\a"
    window.destroy
  end
end
