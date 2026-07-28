# The `items` attribute emitter/applier shared by `Crysterm::Widget::List` and
# `Crysterm::Mixin::ActionBar`: rows are loadable state but don't fit the
# generic scan (no scalar `items=`), so they serialize as a newline-joined
# `items` attribute and restore via `#add_item`.
#
# A macro, deliberately — do NOT "clean this up" into an included module: the
# autoserialize sweep opts a type out only when `dom_attributes`/`dom_apply` are
# among the type's *own* methods (`dom_autoserialize.cr`'s `t.methods.any?`
# guard), and only macro expansion puts real methods in the invoking class body.
# Hosting these on a module would silently re-enroll `Widget::List` in the
# generated scan. Top-level like `dom_autoserialize_body`, since macro lookup
# does not walk the enclosing namespace chain.
macro dom_items_serialization
  def dom_attributes : Hash(String, String?)
    attrs = super
    attrs["items"] = item_texts.join('\n') unless item_texts.empty?
    attrs
  end

  def dom_apply(key : String, value : String?) : Bool
    case key
    when "items"
      # Replace, don't append: `setAttribute` has replace semantics, and at
      # load time the list is empty so clearing first is a no-op. Without the
      # clear, a repeated `setAttribute("items", …)` would grow the list on
      # every call.
      clear
      # An empty value skips the append: `"".split('\n') == [""]`, so
      # `setAttribute("items", "")` — the natural way a client clears the rows —
      # would otherwise add one empty item.
      value.try { |v| v.split('\n').each { |item| add_item item } unless v.empty? }
    else return super
    end
    true
  end
end

module Crysterm
  # Per-widget layout-DOM overrides.
  #
  # Opt-in is automatic by namespace — every `Crysterm::Widget::*` is
  # serializable/loadable, with options derived from initializer arguments. A
  # widget appears here only when it needs to hand-write
  # `#dom_attributes`/`#dom_apply` for state the automatic scan can't express,
  # which also opts it out of that scan.
  class Widget
    class List
      # Expanded into the class body, so `List` stays opted out of the
      # autoserialize sweep (see the macro's note).
      dom_items_serialization
    end
  end

  module Mixin
    # Item views build their rows from a serialized attribute (`items`), never
    # from child nodes — the backing boxes ARE the children. See
    # `Widget#dom_owns_children?`.
    module ItemView
      def dom_owns_children? : Bool
        true
      end
    end

    # Action bars (ListBar / MenuBar / ToolBar) own their children the same way
    # item views do: `#add_item` macro-builds one `Box` per command, so
    # serializing those boxes as `<w-box>` children would reload them as dead
    # lookalikes with an empty command model. Instead the command *model* is
    # serialized as a newline-joined `items` attribute and rebuilt through
    # `#add_item`, mirroring `Widget::List` above.
    #
    # Defined on the module, these handlers do NOT opt the bar classes out of
    # the autoserialize sweep (its guard checks class-body methods only): each
    # bar still gets a generated per-class wrapper whose `super` reaches these,
    # so `items` plus the scanned per-class options all serialize, without
    # duplication.
    #
    # Deliberately lossy, matching `List`: callbacks/hotkeys are code and stay
    # behind; separators reload as ordinary items (`item_texts` carries clean
    # text only).
    module ActionBar
      def dom_owns_children? : Bool
        true
      end

      # Same emitter/applier as `Widget::List`. Expanded here into the *module*
      # body, which — unlike `List`'s class-body expansion — leaves the bar
      # classes enrolled in the autoserialize sweep, as described above.
      dom_items_serialization
    end
  end
end
