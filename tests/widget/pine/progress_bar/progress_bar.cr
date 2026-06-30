# Example: Crysterm::Widget::Pine::ProgressBar
#
# Minimal, self-contained example of a single Pine percent-done ProgressBar.
# Run it:     crystal run examples/widget/pine/progress_bar/progress_bar.cr
# Maintained by tools/manage-examples.cr
require "../../example"

Crysterm::WidgetExample.run("ProgressBar",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.5
    # Ramp the value up and back to its initial 45 (read-only widget, no keys —
    # reach it via the screen and set #value, guarded by the concrete type).
    [45, 60, 75, 90, 100, 75, 45].each do |v|
      d.act(dwell: 0.4) { |s| s.children.each { |c| c.value = v if c.is_a?(Crysterm::Widget::Pine::ProgressBar) } }
    end
  }) do |screen|
  screen.stylesheet = "ProgressBar { color: #7aa2f7; }"
  bar = Crysterm::Widget::Pine::ProgressBar.new parent: screen, top: "center", left: "center", width: 40
  bar.value = 45
end
