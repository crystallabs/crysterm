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
    # destroyed. Returns the `Subscription` so it can be cancelled early.
    #
    # ```
    # names = Crysterm::Reactive::ObservableList(String).new %w[Ada Alan]
    # Crysterm::Reactive.bind_items(list_widget, names, &.itself)
    # names << "Grace"    # one row appended
    # names[0] = "Ada L." # one row's text updated
    # ```
    def self.bind_items(view : V, list : ObservableList(T), &render : T -> String) : ::Crysterm::Subscription forall V, T
      fill = -> {
        rendered = [] of String
        list.each { |e| rendered << render.call(e) }
        view.items = rendered
        nil
      }
      fill.call

      sub = ::Crysterm::Subscription.new
      sub.on(list, ::Crysterm::Event::ListChanged) do |ev|
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
            break if ev.index >= view.items.size
            view.remove_item view.items[ev.index]
          end
        when .update?
          view.set_item ev.index, render.call(list[ev.index])
        when .reset?
          fill.call
        end
        view.window?.try &.schedule_render
      end

      view.on(::Crysterm::Event::Destroy) { sub.off }
      sub
    end
  end
end
