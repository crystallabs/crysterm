require "event_handler"

require "./action"

module Crysterm
  # Groups `Action`s so they behave as one, modeled after Qt's `QActionGroup`.
  #
  # The usual reason is **exclusivity**: a set of checkable actions (a view-mode
  # or encoding menu, a toolbar of mutually exclusive tools) of which exactly one
  # is checked at a time. Checking one unchecks the rest, whichever surface —
  # menu, tool button, shortcut — the user activated it from.
  #
  # ```
  # group = Crysterm::ActionGroup.new
  # %w[Icons List Details].each do |mode|
  #   a = Crysterm::Action.new mode, checkable: true
  #   group << a
  #   menu.add_action a
  # end
  # group.actions.first.checked = true
  # group.on(Crysterm::Event::Triggered) { view.mode = group.checked_action.try &.text }
  # ```
  #
  # NOTE `Mixin::ExclusiveGroup` is the *widget*-side counterpart (it excludes
  # peer `Widget`s, and backs `RadioButton`/`ButtonGroup`); this one operates on
  # `Action`s, which have no widget of their own and may be presented by several
  # widgets at once.
  class ActionGroup
    include EventHandler

    # The member actions, in insertion order (Qt's `QActionGroup#actions`).
    getter actions = [] of Action

    # Whether checking one member unchecks the others (Qt's
    # `QActionGroup#exclusive`). On by default, as in Qt.
    property? exclusive : Bool = true

    # Per-member subscriptions, so `#remove_action` detaches exactly the handlers
    # this group installed and leaves the caller's own alone.
    @subs = {} of Action => Subscriptions

    def initialize(*, exclusive : Bool = true)
      @exclusive = exclusive
    end

    # Adds *action* to the group and returns it (Qt's `QActionGroup#addAction`).
    # Idempotent. An exclusive group forces its members checkable, as Qt does —
    # exclusivity is meaningless without a checked state.
    def add_action(action : Action) : Action
      return action if @actions.includes? action
      @actions << action
      action.checkable = true if exclusive?
      subs = @subs[action] = Subscriptions.new
      # Relay the member's activation as the group's own signal, carrying the
      # post-activation checked state.
      subs.on(action, ::Crysterm::Event::Triggered) do |e|
        enforce_exclusivity action
        emit ::Crysterm::Event::Triggered, e.checked
      end
      # A member checked programmatically (not via activation) must un-check the
      # rest too, else the group could show two checked entries.
      subs.on(action, ::Crysterm::Event::Toggled) do |e|
        enforce_exclusivity action if e.checked
      end
      action
    end

    # :ditto:
    def <<(action : Action) : self
      add_action action
      self
    end

    # Removes *action* from the group, dropping the group's own handlers on it.
    # The action itself is left intact (still checkable, still checked).
    def remove_action(action : Action) : Nil
      return unless @actions.delete action
      @subs.delete(action).try &.off
    end

    # The currently checked member, or `nil` when none is (Qt's
    # `QActionGroup#checkedAction`).
    def checked_action : Action?
      @actions.find &.checked?
    end

    # Whether *any* member is enabled — the group has no enabled state of its
    # own; `#enabled=` simply pushes onto the members (as Qt's does).
    def enabled? : Bool
      @actions.any? &.enabled?
    end

    # Enables/disables every member at once (Qt's `QActionGroup#setEnabled`),
    # e.g. to grey out a whole view-mode menu.
    def enabled=(value : Bool) : Bool
      @actions.each(&.enabled=(value))
      value
    end

    # :ditto: `#enabled?`, for visibility.
    def visible? : Bool
      @actions.any? &.visible?
    end

    # Shows/hides every member at once (Qt's `QActionGroup#setVisible`).
    def visible=(value : Bool) : Bool
      @actions.each(&.visible=(value))
      value
    end

    # Unchecks every member other than *keep*. No-op for a non-exclusive group,
    # or when *keep* isn't checked (a member being *un*checked leaves the group
    # with none checked, which Qt allows — it never forces one back on).
    private def enforce_exclusivity(keep : Action) : Nil
      return unless exclusive?
      return unless keep.checked?
      @actions.each do |a|
        next if a.same? keep
        a.checked = false
      end
    end
  end
end
