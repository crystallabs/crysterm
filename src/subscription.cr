module Crysterm
  # A single event subscription that remembers how to cancel itself. The
  # generic implementation lives in the event_handler shard — see
  # `EventHandler::Subscription` for the semantics (`#on` re-arms, `#off` is
  # idempotent, `dispose`/`disposed?` are the reactive-stack aliases).
  alias Subscription = ::EventHandler::Subscription

  # A bag of `Subscription`s torn down together (`EventHandler::Subscriptions`),
  # extended with the one crysterm-specific hook: `#auto_dispose`.
  class Subscriptions < ::EventHandler::Subscriptions
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
  end
end
