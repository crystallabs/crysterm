require "crystallabs-helpers"

module Crysterm
  # An emacs/readline-style kill ring — see `Crystallabs::Helpers::KillRing`,
  # where the implementation now lives (it is fully generic).
  #
  # The process-wide `KillRing.default` instance is shared by every
  # text-editable widget, so text killed in one field can be yanked into
  # another. An application may swap `KillRing.default`, or give a single
  # widget its own ring via `Mixin::TextEditing#kill_ring=`.
  alias KillRing = Crystallabs::Helpers::KillRing
end
