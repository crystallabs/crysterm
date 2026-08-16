module Crysterm
  module Reactive
    # Binds a side effect to one or more properties. Whenever any of *properties*
    # changes, *block* runs and a repaint is scheduled for *owner*. The binding
    # runs once immediately, so *owner* reflects current state at bind time, and
    # is disposed automatically when *owner* emits `Event::Destroy`.
    #
    # *owner* is any `EventHandler` — a `Widget`, a `Window`, an `Action` or a
    # model object of your own — and supplies the binding's *lifetime*. When it
    # is paintable the run also schedules a frame (see `.request_repaint`).
    #
    # Dependencies are **explicit**: you name the properties to watch, and the
    # watched set is fixed for the binding's life. For a side effect whose
    # dependency *set* changes between runs, use the re-tracking `Effect`.
    #
    # Returns the `Binding` so it can be disposed early by hand if needed.
    #
    # ```
    # count = Crysterm::Reactive::Property.new 0
    # Crysterm::Reactive.bind(label, count) { label.content = "Count: #{count.value}" }
    # count.value = 5 # label.content is now "Count: 5"; a repaint is scheduled
    # ```
    def self.bind(owner : ::EventHandler, *properties : PropertyBase, &block : ->) : Binding
      binding = Binding.new owner, block
      properties.each { |s| binding.watch s }
      binding.attach_auto_dispose
      binding.run
      binding
    end

    # Schedules a repaint on behalf of a binding/effect that just ran.
    #
    # An owner is any `EventHandler` — the object whose `Event::Destroy` ends the
    # binding's life. Only the paintable ones have anything to repaint: a
    # `Widget` marks itself damaged and rings the render doorbell (`#update!`), a
    # `Window` rings the doorbell (`#update`). An `Action`, a `Reactive::Property`
    # or a plain model object owns the lifetime only, and this is a no-op for it.
    protected def self.request_repaint(owner : ::EventHandler?) : Nil
      case owner
      when ::Crysterm::Widget then owner.update!
      when ::Crysterm::Window then owner.update
      end
    end
  end
end
