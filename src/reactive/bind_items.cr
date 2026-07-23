module Crysterm
  module Reactive
    # Binds an item view (`Widget::List`/`Tree`/`Menu`/… — anything including
    # `Mixin::ItemView`) to an `ObservableList`, keeping the widget's rows in
    # sync with the collection. *render* maps each element to display text.
    #
    # The view is filled once immediately, then patched incrementally on each
    # `Event::ListChanged`: an insert adds just those rows, a remove drops just
    # those, an update rewrites one row, and only a reset rebuilds. A repaint is
    # scheduled after each change, and the binding is torn down when the view is
    # destroyed. Returns the `Subscriptions` bag so the binding can be cancelled
    # early with `#off` — which also unhooks the auto-teardown `Destroy` hook,
    # so a view rebound repeatedly accumulates no dead handlers.
    #
    # ```
    # names = Crysterm::Reactive::ObservableList(String).new %w[Ada Alan]
    # Crysterm::Reactive.bind_items(list_widget, names, &.itself)
    # names << "Grace"    # one row appended
    # names[0] = "Ada L." # one row's text updated
    # ```
    def self.bind_items(view : V, list : ObservableList(T), &render : T -> String) : ::Crysterm::Subscriptions forall V, T
      fill = -> {
        rendered = [] of String
        list.each { |e| rendered << render.call(e) }
        view.items = rendered
        nil
      }
      fill.call

      subs = ::Crysterm::Subscriptions.new
      subs.on(list, ::Crysterm::Event::ListChanged) do |ev|
        case ev.op
        when .insert?
          # Ascending order: each insert shifts later rows down, so inserting the
          # new indices low-to-high lands each at its final slot.
          (0...ev.count).each do |k|
            i = ev.index + k
            view.insert_item i, render.call(list[i])
          end
        when .remove?
          # Remove `count` rows at `index`: after each removal later rows slide
          # down, so the row now *at* `index` is the next one to drop.
          ev.count.times do
            break if ev.index >= view.item_boxes.size
            # Remove by box identity, not by text: two rows can share text, and
            # `remove_item(String)` would drop the first match rather than the
            # one now at `ev.index`.
            view.remove_item view.item_boxes[ev.index]
          end
        when .update?
          view.set_item ev.index, render.call(list[ev.index])
        when .reset?
          fill.call
        end
        view.window?.try &.update
      end

      # Tearing down the whole bag also removes this very hook (safe mid-emit:
      # the handler list is copy-on-write), so neither the view's destruction
      # nor an early `#off` by the caller leaves a dead handler on the view.
      subs.on(view, ::Crysterm::Event::Destroy) { subs.off }
      subs
    end
  end
end
