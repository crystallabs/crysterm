module Crysterm
  # A single event subscription that remembers how to cancel itself.
  #
  # Wraps the `on` → store-`Wrapper` → `off` triple that a dozen-odd widgets
  # hand-rolled. Each of those sites names the event type twice (once to
  # subscribe, once to remove) and several tore down against a *different*
  # reference than they subscribed on (`window` on install, `window?` on
  # teardown) — a latent leak when the owner detaches before teardown and
  # `window?` has already gone nil.
  #
  # This captures the *target* at subscribe time inside the cancel closure, so
  # `#off` always removes from the exact object it added to, regardless of the
  # owner's later `window?`. `#off` is idempotent, so a dismiss path and a
  # `#destroy` can both call it without double-freeing, and `#on` re-installs
  # cleanly (it cancels any previous handler first, so a slot re-armed on every
  # focus can't leak the old one).
  #
  # The stored canceller is erased to `Proc(Nil)`, so no site pays the cost of a
  # concrete `Event::Foo::Wrapper?` field per subscription, and a heterogeneous
  # set of subscriptions (see `Subscriptions`) can be tracked in one collection.
  class Subscription
    @cancel : Proc(::Nil)?

    # Whether a handler is currently installed.
    def active? : Bool
      !@cancel.nil?
    end

    # Subscribes *block* to event *type* on *target*, first cancelling any
    # handler this slot already holds. *target* is any event emitter (a `Widget`,
    # `Window`, `Screen`, `GlobalEvents`, …). Returns `self`.
    def on(target, type : T.class, once = false, async = ::EventHandler.async?,
           at = ::EventHandler.at_end, &block : T -> ::Nil) : self forall T
      off
      wrapper = target.on(type, once, async, at, &block)
      @cancel = -> { target.off(type, wrapper); nil }
      self
    end

    # Removes the handler if one is installed. Idempotent.
    def off : ::Nil
      if c = @cancel
        @cancel = nil
        c.call
      end
    end
  end

  # A bag of `Subscription`s that are torn down together — the common
  # "install several window/self handlers, `off` them all in `#destroy`/`#detach`"
  # shape. `#on` adds a tracked subscription (and returns it, so a single one can
  # still be re-armed or cancelled individually); `#off` cancels every remaining
  # subscription, idempotently.
  class Subscriptions
    @subs = [] of Subscription

    # Subscribes *block* to *type* on *target*, tracking it for a later bulk
    # `#off`. Returns the created `Subscription`.
    def on(target, type : T.class, once = false, async = ::EventHandler.async?,
           at = ::EventHandler.at_end, &block : T -> ::Nil) : Subscription forall T
      s = Subscription.new
      s.on(target, type, once, async, at, &block)
      @subs << s
      s
    end

    # Cancels every tracked subscription and empties the bag. Idempotent.
    def off : ::Nil
      @subs.each &.off
      @subs.clear
    end

    # Whether the bag holds no subscriptions.
    def empty? : Bool
      @subs.empty?
    end
  end
end
