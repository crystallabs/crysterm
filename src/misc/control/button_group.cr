require "event_handler"

module Crysterm
  # Logical, non-visual grouping of checkable buttons, modeled after Qt's
  # `QButtonGroup`.
  #
  # Unlike `Widget::RadioSet` (which groups radio buttons by *widget-tree
  # containment*), a `ButtonGroup` groups buttons regardless of where they sit
  # in the layout. In the default *exclusive* mode it enforces radio behaviour:
  # checking one member unchecks the others, so at most one stays checked. Set
  # `#exclusive = false` to let any number be checked at once (e.g. independent
  # toggle buttons that still report through one handler).
  #
  # Members may be any checkable button — a `Widget::Button` (it is switched to
  # `checkable` automatically on add), a `Widget::CheckBox`, or a
  # `Widget::RadioButton`. Each may carry an integer *id*; `#checked_id` and
  # `#button` map between ids and buttons (an unset id is `-1`, as in Qt).
  #
  # The group emits `Event::ButtonClick` (carrying the button) whenever a member
  # is checked.
  #
  # ```
  # group = ButtonGroup.new
  # group.add bold, 1
  # group.add italic, 2
  # group.on(Crysterm::Event::ButtonClick) do |e|
  #   puts "now checked: id #{group.checked_id}"
  # end
  # ```
  class ButtonGroup
    include EventHandler

    # Whether at most one member may be checked at a time (Qt's
    # `QButtonGroup#exclusive`). Defaults to `true`.
    property? exclusive : Bool = true

    @buttons = [] of Widget
    @ids = {} of Widget => Int32
    # Per-button `Event::Check` listener handles, so `#remove` can detach again.
    @handlers = {} of Widget => Crysterm::Event::Check::Wrapper
    # Guards the cascade: unchecking siblings must not itself trigger another
    # round of exclusivity handling.
    @suppress = false

    def initialize(exclusive : Bool = true)
      @exclusive = exclusive
    end

    # The members, in the order they were added.
    def buttons : Array(Widget)
      @buttons
    end

    # Adds *button* with an optional *id* (`-1` means "no id", like Qt). A plain
    # `Widget::Button` is made `checkable` so it can participate. Returns the
    # button.
    def add(button : Widget, id : Int32 = -1) : Widget
      return button if @buttons.includes? button
      button.checkable = true if button.is_a?(Widget::AbstractButton) && !button.checkable?
      @buttons << button
      @ids[button] = id
      @handlers[button] = button.on(Crysterm::Event::Check) do |_|
        on_member_checked button
      end
      button
    end

    # Removes *button* from the group and detaches its listener.
    def remove(button : Widget) : Nil
      return unless @buttons.includes? button
      @handlers.delete(button).try { |w| button.off Crysterm::Event::Check, w }
      @ids.delete button
      @buttons.delete button
    end

    # The id assigned to *button* (`-1` if none / not a member).
    def id(button : Widget) : Int32
      @ids[button]? || -1
    end

    # The member with the given *id*, or `nil`.
    def button(id : Int32) : Widget?
      @buttons.find { |b| @ids[b]? == id }
    end

    # The currently-checked member, or `nil` (in a non-exclusive group with
    # several checked, the first one added).
    def checked_button : Widget?
      @buttons.find { |b| member_checked? b }
    end

    # The id of the currently-checked member, or `-1`.
    def checked_id : Int32
      (b = checked_button) ? id(b) : -1
    end

    # Reacts to a member becoming checked: in exclusive mode, unchecks the
    # others; then re-announces the click on the group.
    private def on_member_checked(button : Widget) : Nil
      return if @suppress
      if exclusive?
        @suppress = true
        @buttons.each { |b| member_uncheck b unless b == button }
        @suppress = false
      end
      emit Crysterm::Event::ButtonClick, button
    end

    # `Button` and `CheckBox` share the `#checked?`/`#uncheck` interface but have
    # no common type that declares it, so dispatch concretely.
    private def member_checked?(b : Widget) : Bool
      case b
      when Widget::CheckBox then b.checked?
      when Widget::Button   then b.checked?
      else                       false
      end
    end

    private def member_uncheck(b : Widget) : Nil
      case b
      when Widget::CheckBox then b.uncheck
      when Widget::Button   then b.uncheck
      end
    end
  end
end
