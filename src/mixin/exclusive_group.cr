module Crysterm
  module Mixin
    # The "at most one checked" rule shared by the exclusive-selection models:
    # when a member becomes checked, uncheck every other checked member.
    #
    # The including type supplies its own notion of membership and iteration, and
    # any re-entrancy guard. The "non-empty" guarantee is likewise per-model
    # policy, not enforced here.
    module ExclusiveGroup
      # Applies the exclusive rule to one peer *m* relative to *keep* (the member
      # that just became the selection): unchecks *m* iff it is a *different*,
      # currently-checked checkable. The `#checked?` guard avoids a spurious
      # `Event::StateChanged`.
      protected def exclude_peer(m : Widget, keep : Widget) : Nil
        return unless m.is_a?(Widget::AbstractButton)
        m.uncheck if m != keep && m.checked?
      end

      # `#exclude_peer` for each of *members*.
      protected def exclude_peers(members : Enumerable(Widget), keep : Widget) : Nil
        members.each { |m| exclude_peer m, keep }
      end
    end
  end
end
