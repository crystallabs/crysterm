require "./spec_helper"

# Regression spec for the BUGS7 Remote/DOM fix. Guarded by -Dremote like the
# other bridge specs; run with:
#   crystal spec -Dremote spec/bugs7_remote_spec.cr
#
# The declarative `add-class`/`remove-class`/`toggle-class` verbs split the
# payload on the first remaining `:`, but a target *selector* legitimately
# contains a `:` (a pseudo-class). `toggle-class:.tab:not(.x):active` must toggle
# `active` on `.tab:not(.x)`, not the bogus class `not(.x):active` on `.tab`. The
# fix splits the class token off the right (`rpartition`).
{% if flag?(:remote) %}
  include Crysterm

  private def rem_window(w = 20, h = 6)
    Crysterm::Window.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: w, height: h)
  end

  describe "BUGS7 declarative *-class verbs keep a pseudo-class in the selector" do
    it "toggles the right class when the selector carries a pseudo-class" do
      s = rem_window
      box = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
      box.add_css_class "tab"
      s._render

      # `:not(.x)` is a real pseudo-class the selector engine matches statically,
      # and it carries a colon — so the class token must be split off the right.
      Crysterm::DOM::Actions.run("toggle-class:.tab:not(.x):active", box.as(Widget), s)

      box.css_classes.includes?("active").should be_true          # the real class toggled on
      box.css_classes.includes?("not(.x):active").should be_false # not the mis-split token
    end

    it "still handles a colon-free selector (no regression)" do
      s = rem_window
      box = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
      box.add_css_class "tab"
      s._render

      Crysterm::DOM::Actions.run("add-class:.tab:active", box.as(Widget), s)
      box.css_classes.includes?("active").should be_true
    end
  end
{% end %}
