module Crysterm
  class Widget
    # Box element
    class Box < Widget
      # XXX Why this must be here, even though it's set in src/widget_size.cr?
      # Check e.g. small-tests/shadow.cr with and without this option here.
      @resizable = false
    end
  end
end
