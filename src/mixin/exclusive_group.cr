module Crysterm
  module Mixin
    # The "at most one checked" contract shared by the two exclusive-selection
    # models in the toolkit:
    #
    #   * `Widget::RadioButton` — *implicit* grouping by widget-tree containment
    #     (the radios under a common `Widget::RadioSet`); each radio reacts to its
    #     own `Event::Check` by unchecking its siblings.
    #   * `ButtonGroup` — *explicit* grouping by an added-member list, regardless
    #     of layout; the group reacts to any member's `Event::Check`.
    #
    # Both enforce the same core rule when a member becomes checked: uncheck every
    # *other* currently-checked member. That decision (`#exclude_peer`) lives here
    # so the two models can't drift — each keeps only what legitimately differs
    # (who counts as a member, and any re-entrancy guard).
    #
    # Intended, documented difference in the "non-empty" guarantee: `ButtonGroup`
    # additionally forbids unchecking the sole selected member (it reverts via an
    # `Event::UnCheck` listener). `RadioButton` prevents *interactive* emptying a
    # different way — its `#toggle` only ever checks — but permits a programmatic
    # `#uncheck` to clear the set. This module owns the shared enforcement only,
    # not that per-model policy.
    module ExclusiveGroup
      # Applies the exclusive rule to one peer *m* relative to *keep* (the member
      # that just became the selection): unchecks *m* iff it is a *different*,
      # currently-checked checkable. Each model keeps its own iteration and its
      # own notion of membership (`ButtonGroup` over its explicit list;
      # `RadioButton` over its `RadioSet`'s descendant radios) and calls this per
      # candidate, so only the decision is shared. Unchecking an already-unchecked
      # member is a no-op, so the `#checked?` guard just avoids a spurious
      # `Event::UnCheck`.
      protected def exclude_peer(m : Widget, keep : Widget) : Nil
        return unless m.is_a?(Widget::AbstractButton)
        m.uncheck if m != keep && m.checked?
      end

      # Convenience over an explicit member list (the `ButtonGroup` shape):
      # `#exclude_peer` for each of *members*.
      protected def exclude_peers(members : Enumerable(Widget), keep : Widget) : Nil
        members.each { |m| exclude_peer m, keep }
      end
    end
  end
end
