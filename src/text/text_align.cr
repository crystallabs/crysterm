module Crysterm
  # The horizontal-alignment keyword ↔ `Tput::AlignFlag` map, shared by the
  # text import/export layers (`TextHtml`, `TextTags`) and the stylesheet's
  # `text-align` handling. Nothing here is format-specific — it is the one
  # place the `"left"`/`"center"`/`"right"` vocabulary is translated.
  module TextAlign
    # Resolves a horizontal-alignment keyword (`"left"`/`"center"`/`"right"`,
    # already case-folded) to a `Tput::AlignFlag` — horizontal center is
    # `HCenter` — or `nil` for an unrecognized name. Callers apply their own
    # default for the `nil` case.
    def self.align_flag(name : String) : Tput::AlignFlag?
      case name
      when "left"   then Tput::AlignFlag::Left
      when "center" then Tput::AlignFlag::HCenter
      when "right"  then Tput::AlignFlag::Right
      end
    end

    # The reverse of `align_flag`: a `Tput::AlignFlag` to its alignment
    # keyword (`"left"`/`"center"`/`"right"`, horizontal center as `"center"`),
    # or `nil` when it carries no horizontal alignment.
    def self.align_name(a : Tput::AlignFlag?) : String?
      return unless a
      return "center" if a.h_center?
      return "right" if a.right?
      return "left" if a.left?
      nil
    end
  end
end
