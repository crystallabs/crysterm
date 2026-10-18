module Crysterm
  module Reactive
    # Keeps two properties of one type equal, in both directions: *b* takes
    # *a*'s value first, then an assignment to either is put into the other,
    # so whatever is bound to either side (`Reactive.bind`,
    # `Action#bind_checked`) follows. For one setting shown in two places —
    # an application's menu entry and the document it acts on. The link
    # lasts as long as *owner* — a `Window`, a `Widget`, any `EventHandler`
    # whose `Event::Destroy` ends it — or, without one, until
    # `PropertyLink#dispose`.
    #
    # The copy back into the side that changed is cut by the property's own
    # guard (an assignment of an equal value is a no-op), so the loop
    # a → b → a stops after one step, as `.link_config`'s does. A handler
    # that changes its side again while the change is going round (one that
    # clamps what it is given) is still heard: its value goes across too.
    #
    # ```
    # watch = Crysterm::Reactive.property false
    # Crysterm::Reactive.link watch, document.watch_file, window
    # watch.value = true # document.watch_file is now true
    # ```
    def self.link(a : Property(T), b : Property(T), owner : ::EventHandler? = nil) : PropertyLink forall T
      b.value = a.peek
      link = PropertyLink.new
      link.watch a, b
      link.attach_auto_dispose owner if owner
      link
    end

    # The two-way link `Reactive.link` makes between two properties:
    # disposing it unhooks both sides; their values stay as they are.
    class PropertyLink < Link
      # Hooks the two sides: an assignment to either puts its value into the
      # other.
      protected def watch(a : Property(T), b : Property(T)) : Nil forall T
        @subs.on(a, ::Crysterm::Event::ReactiveChanged) { b.value = a.peek }
        @subs.on(b, ::Crysterm::Event::ReactiveChanged) { a.value = b.peek }
      end
    end
  end
end
