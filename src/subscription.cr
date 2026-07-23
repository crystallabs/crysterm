module Crysterm
  # A single event subscription that remembers how to cancel itself.
  #
  # The *target* is captured at subscribe time inside the cancel closure, so
  # `#off` always removes from the exact object it added to, regardless of the
  # owner's later `window?`. `#off` is idempotent, so a dismiss path and a
  # `#destroy` can both call it without double-freeing; `#on` cancels any
  # previous handler first, so a slot re-armed on every focus can't leak.
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

  # A bag of `Subscription`s that are torn down together. `#on` adds a tracked
  # subscription and returns it, so a single one can still be re-armed or
  # cancelled individually; `#off` cancels every remaining one, idempotently.
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

    # Hooks *teardown* to *owner*'s `Event::Destroy`, routed through this bag so a
    # later `#off` also removes the hook — a bag torn down early by hand must not
    # leave a dead `Destroy` handler (pinning *owner*'s subscribers and everything
    # the closure captured) on the long-lived *owner*. The self-unhook is safe
    # mid-emit: the handler list is copy-on-write.
    #
    # This is the bag-routed auto-dispose idiom; `Reactive::Effect` keeps a
    # divergent standalone-`Subscription` variant (it stores per-signal subs in a
    # Hash, not a bag, and attaches its `Destroy` hook *after* its initial run, so
    # it needs an extra `disposed?` guard) — see `Reactive.effect`.
    def auto_dispose(owner, &teardown : ->) : Subscription
      on(owner, ::Crysterm::Event::Destroy) { teardown.call }
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
