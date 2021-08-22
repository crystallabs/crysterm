module Crysterm
  class Widget < ::Crysterm::Object
    property? focus_on_click = false

    # Puts current widget in focus
    def focus
      # XXX Prevents getting multiple `Event::Focus`s. Remains to be
      # seen whether that's good, or it should always happen, even
      # if someone calls `#focus` multiple times in a row.
      return if focused?
      screen.focused = self
    end

    # Returns whether widget is currently in focus
    @[AlwaysInline]
    def focused?
      screen.focused == self
    end
  end
end
