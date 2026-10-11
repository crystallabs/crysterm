require "../action"
require "./bind"

module Crysterm
  class Action
    # Keeps `#checked` on *property*'s value, and *property* on `#checked`
    # whenever the action is triggered: the two-way link between a
    # checkable menu entry and the `Bool` it stands for (View → Follow
    # cursor). Qt's idiom in two connections — the property's change signal
    # to `setChecked`, `triggered(bool)` to the setter — with the action
    # owning the binding's lifetime (`Reactive.bind`).
    #
    # ```
    # follow = Crysterm::Reactive::Property.new false
    # action = Crysterm::Action.new "&Follow cursor", checkable: true
    # action.bind_checked follow
    # follow.value = true # the entry is checked
    # action.trigger      # follow.value is false again
    # ```
    def bind_checked(property : Reactive::Property(Bool)) : Reactive::Binding
      on(::Crysterm::Event::Triggered) { |e| property.value = e.checked }
      Reactive.bind(self, property) { self.checked = property.value }
    end

    # Keeps `#checked` on *block*'s answer, asked again whenever any of
    # *properties* changes — a derived check, such as one entry of a radio
    # group standing for one value of an enum property.
    #
    # ```
    # mode = Crysterm::Reactive::Property.new MouseMode::All
    # action.bind_checked(mode) { mode.value == MouseMode::Never }
    # ```
    def bind_checked(*properties : Reactive::PropertyBase, &block : -> Bool) : Reactive::Binding
      Reactive.bind(self, *properties) { self.checked = block.call }
    end

    # Keeps `#checked` on *block*'s answer, asked now and again on every
    # *event* from *source* — for state a widget reports through an event
    # rather than a property. The subscription ends with the action
    # (`#destroy`), as a Qt connection ends with either object; it is
    # returned for ending it earlier.
    #
    # ```
    # action.bind_checked(editor, Crysterm::Event::OverwriteModeChanged) { editor.overwrite_mode? }
    # ```
    def bind_checked(source : ::EventHandler, event : E.class, &block : -> Bool) : ::EventHandler::Subscription forall E
      self.checked = block.call
      follow(source, event) { self.checked = block.call }
    end

    # Keeps `#enabled` on *block*'s answer, asked again whenever any of
    # *properties* changes (`#bind_checked`'s counterpart).
    def bind_enabled(*properties : Reactive::PropertyBase, &block : -> Bool) : Reactive::Binding
      Reactive.bind(self, *properties) { self.enabled = block.call }
    end

    # Keeps `#enabled` on *block*'s answer, asked now and again on every
    # *event* from *source*; the subscription ends with the action.
    def bind_enabled(source : ::EventHandler, event : E.class, &block : -> Bool) : ::EventHandler::Subscription forall E
      self.enabled = block.call
      follow(source, event) { self.enabled = block.call }
    end

    # The subscriptions on other emitters this action's bindings hold
    # (`Subscriptions`), ended by `#destroy`.
    @bound_subs : Crysterm::Subscriptions?

    # Subscribes *block* to *event* on *source* for as long as this action
    # lives: `#destroy` ends the subscription.
    private def follow(source : ::EventHandler, event : E.class, &block : ->) : ::EventHandler::Subscription forall E
      subs = @bound_subs ||= Crysterm::Subscriptions.new
      subs.on(source, event) { block.call }
    end

    # Ends the action, as `~QAction` does: emits `Event::Destroy`, so the
    # bindings owned through it let go (`Reactive.bind`'s auto-dispose),
    # ends the event subscriptions of `#bind_checked`/`#bind_enabled`, then
    # drops every handler on it. Menus and tool bars holding the action
    # are not told; remove it from them first.
    def destroy : Nil
      emit ::Crysterm::Event::Destroy
      @bound_subs.try &.off
      remove_all_handlers
    end
  end
end
