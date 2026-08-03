module Crysterm
  module Chat
    # The chat UI's permission-mode machine, declared in definition order =
    # `Shift+Tab` cycle order (`Normal → AutoAccept → Plan → Bypass`, then
    # wrapping). Kept in the model layer (`Crysterm::Chat`, not
    # `Widget::Chat`): the mode colors more than the status badge — input
    # border accents and permission prompts key off it too.
    enum Mode
      # Every privileged action asks first; no badge.
      Normal
      # Edits apply without confirmation.
      AutoAccept
      # Read-only planning; no edits.
      Plan
      # Permission checks skipped entirely.
      Bypass

      # The next mode in cycle order, wrapping after the last.
      def next : Mode
        members = Mode.values
        members[(members.index!(self) + 1) % members.size]
      end

      # The status-badge label; empty for `Normal` (the default mode shows no
      # badge).
      def label : String
        case self
        in .normal?      then ""
        in .auto_accept? then "⏵⏵ accept edits on"
        in .plan?        then "⏸ plan mode on"
        in .bypass?      then "⏵⏵ bypass permissions on"
        end
      end

      # The `{}`-tag color name accents (badge, input border) use for this
      # mode, or `nil` for `Normal` (unstyled).
      def color : String?
        case self
        in .normal?      then nil
        in .auto_accept? then "magenta"
        in .plan?        then "cyan"
        in .bypass?      then "red"
        end
      end
    end
  end
end
