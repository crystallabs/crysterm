require "event_handler"
require "../../mixin/exclusive_group"

module Crysterm
  # Logical, non-visual grouping of checkable buttons, modeled after Qt's
  # `QButtonGroup`.
  #
  # Unlike `Widget::RadioSet` (which groups radio buttons by widget-tree
  # containment), a `ButtonGroup` groups buttons regardless of where they sit
  # in the layout. In the default exclusive mode it enforces radio behaviour:
  # checking one member unchecks the others, and the checked member cannot be
  # unchecked by clicking it (only by checking another). `Widget::RadioButton`
  # members enforce this themselves; `CheckBox`/`Button` members are kept
  # consistent here so the group behaves uniformly. Set `#exclusive = false`
  # to let any number be checked at once.
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
    include Mixin::ExclusiveGroup

    # Whether at most one member may be checked at a time (Qt's
    # `QButtonGroup#exclusive`). Defaults to `true`.
    property? exclusive : Bool = true

    @buttons = [] of Widget
    @ids = {} of Widget => Int32
    # Per-button `Event::Check`/`Event::UnCheck` subscriptions, bagged together so
    # `#remove` tears down both. Each `Subscriptions` captures the button it was
    # installed on, so teardown reaches the right one regardless of later state.
    @subs = {} of Widget => Subscriptions
    # Guards the cascade: unchecking siblings (and the exclusive re-check
    # revert) must not itself trigger another round of exclusivity handling.
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
      if button.is_a?(Widget::AbstractButton)
        button.checkable = true unless button.checkable?
        # Back-reference for Qt's `QAbstractButton#group`.
        button.group = self
      end
      @buttons << button
      @ids[button] = id
      subs = Subscriptions.new
      subs.on(button, Crysterm::Event::Check) { |_| on_member_checked button }
      subs.on(button, Crysterm::Event::UnCheck) { |_| on_member_unchecked button }
      @subs[button] = subs
      button
    end

    # Removes *button* from the group and detaches its listeners.
    def remove(button : Widget) : Nil
      return unless @buttons.includes? button
      @subs.delete(button).try &.off
      # Only clear the back-reference if it still points here: a button moved
      # to another group is `add`ed there first, and this must not orphan it.
      button.group = nil if button.is_a?(Widget::AbstractButton) && (g = button.group) && g.same?(self)
      @ids.delete button
      @buttons.delete button
    end

    # The id assigned to *button* (`-1` if none / not a member).
    def id(button : Widget) : Int32
      @ids[button]? || -1
    end

    # The member with the given *id*, or `nil`. `-1` is the "no id" sentinel (a
    # member added without an explicit id, and what `#checked_id` returns when
    # nothing is checked), so as in Qt it never addresses a real button:
    # `button(-1)` is always `nil`, even though several un-id'd members carry it.
    def button(id : Int32) : Widget?
      return nil if id == -1
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
      # `suppressed` stops the cascade of unchecks from re-entering this handler.
      suppressed { exclude_peers @buttons, button } if exclusive?
      emit Crysterm::Event::ButtonClick, button
    end

    # Reacts to a member becoming unchecked. In an exclusive group a member
    # cannot be unchecked by clicking it: if unchecking it would leave the group
    # with nothing selected, re-check it. The re-check is `@suppress`ed so it
    # neither cascades nor re-announces a `ButtonClick`.
    #
    # `@suppress` is already set during a legitimate switch (A→B unchecks A), so
    # a normal selection change passes straight through — only a direct uncheck
    # of the sole checked member is reverted. `Widget::RadioButton`'s `#toggle`
    # only ever checks, so this affects only `CheckBox`/`Button` members.
    private def on_member_unchecked(button : Widget) : Nil
      return if @suppress || !exclusive?
      return if @buttons.any? { |b| member_checked? b }
      suppressed { member_check button }
    end

    # Runs *block* with the cascade guard (`@suppress`) raised, so the
    # check/uncheck it performs on member buttons doesn't re-enter the
    # exclusivity handling.
    private def suppressed(& : -> Nil) : Nil
      @suppress = true
      begin
        yield
      ensure
        # Must reset even if a user Check/UnCheck handler raises, or `@suppress`
        # stays set and silently disables exclusivity from then on.
        @suppress = false
      end
    end

    # Dispatch through `Widget::AbstractButton`, which declares the shared
    # `#checked?`/`#uncheck` interface; the concrete leaf types would miss
    # `RadioButton`.
    private def member_checked?(b : Widget) : Bool
      b.is_a?(Widget::AbstractButton) ? b.checked? : false
    end

    private def member_check(b : Widget) : Nil
      b.check if b.is_a?(Widget::AbstractButton)
    end
  end
end
