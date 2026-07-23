require "./box"
require "../mixin/sub_style"

module Crysterm
  class Widget
    # Titled, bordered container, modeled after Qt's `QGroupBox`.
    #
    # Draws a border with the group `#title` as its label and holds arbitrary
    # child widgets. When `#checkable?` a checkbox marker (`[x]`/`[ ]` at the
    # default tier, from the `Glyphs` checkbox roles) is shown in the title and
    # toggling it enables/disables the contained children (Qt greys out a
    # checkable group's contents when unchecked).
    #
    # ```
    # gb = Widget::GroupBox.new parent: window, title: "Options", width: 30, height: 8
    # Widget::CheckBox.new parent: gb, top: 0, content: "Wrap"
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![GroupBox screenshot](../../tests/widget/group_box/group_box.5s.apng)
    # <!-- /widget-examples:capture -->
    class GroupBox < Box
      include Mixin::SubStyle

      getter title : String = ""

      # Updates the stored title and the rendered border label.
      def title=(value : String) : String
        @title = value
        update_label
        request_render
        value
      end

      # Whether the group has a checkable title that enables/disables its
      # contents (Qt's `QGroupBox#checkable`).
      getter? checkable : Bool = false

      # Enabling checkability at runtime also adds the `[x]` marker and wires the
      # title-row click/adopt handlers.
      def checkable=(value : Bool) : Bool
        return value if value == @checkable
        @checkable = value
        update_label
        if value
          install_checkable_handlers
          # Only run the disabling direction here: on a *checked* group (the
          # default) `apply_enabled` takes the `checked?` restore branch, which
          # is meant to undo greying the group itself applied on uncheck — on
          # this path the group never greyed anything, so running it would
          # force-enable every child the app itself disabled.
          apply_enabled unless checked?
        else
          # No longer checkable ⇒ the "disabled because unchecked" reason is
          # gone, and there's no checkbox left to toggle back on. Restore any
          # greyed-out children so the contents stay usable, as Qt does.
          restore_disabled_children
        end
        request_render
        value
      end

      # Guards `#install_checkable_handlers` against double-registration when
      # `checkable=` is toggled more than once.
      @checkable_wired = false

      # Memo for the `::title` sub-style push: the last `style.title` object
      # seen and the border-stripped copy derived from it.
      @_title_style_src : ::Crysterm::Style?
      @_title_style_copy : ::Crysterm::Style?

      # Checked state of a `#checkable?` group; when false the children render
      # disabled.
      getter? checked : Bool = true

      # The `glyph_key` the baked title marker was built from; the `PreRender`
      # handler rebuilds the label when it moves.
      @_label_glyph_key : {String?, Glyphs::Tier, UInt64}?

      # Whether the group is *flat* — drawn without its frame (Qt's
      # `QGroupBox#flat`). Surfaced as the `[flat]` attribute, which the theme
      # targets via `GroupBox[flat]` to strip the default border.
      getter? flat : Bool = false

      def initialize(title = "", checkable = false, checked = true, flat = false, **box)
        @title = title
        @checkable = checkable
        @checked = checked
        @flat = flat

        super **box

        # Titled border is the default look, from the CSS theme
        # (`GroupBox { border: solid }`) so it stays overridable by author CSS.
        update_label

        # `GroupBox::title { … }` styles the title — the auto-created label
        # child, which snapshots its style at creation — so push the computed
        # `title` sub-style onto it each frame after the cascade. A no-op unless
        # a `::title` rule matched.
        on(::Crysterm::Event::PreRender) do
          # The checkable marker is baked into the label at `update_label` time,
          # so a later glyph-tier change (a retheme, or the post-probe auto tier
          # upgrade — widgets are built before the window probes) would leave it
          # stale. Rebuild when the resolved tier/registry generation moves.
          if checkable?
            key = glyph_key(style)
            if @_label_glyph_key != key
              @_label_glyph_key = key
              update_label
            end
          end

          t = style.title
          unless t.same?(style)
            # The title is an inline label, not a framed box, but the `title`
            # sub-style inherits the group's own border — which would draw a full
            # box around the title text. Strip it on an own copy.
            #
            # Cache the stripped copy: the cascade replaces the `::title`
            # sub-`Style` object on recompute (never mutates it), so refresh only
            # when `style.title` returns a different object.
            unless t.same?(@_title_style_src)
              @_title_style_src = t
              c = t.dup
              c.border = false
              @_title_style_copy = c
            end
            if c = @_title_style_copy
              @label_widget.try(&.styles.normal = c)
            end
          end
        end

        install_checkable_handlers if checkable?
      end

      # Wires the title-row toggle-click and the child-adopt reflect handlers.
      # Idempotent via `@checkable_wired`.
      private def install_checkable_handlers : Nil
        return if @checkable_wired
        @checkable_wired = true

        # Toggle only when the *title* row is clicked, as Qt toggles via the
        # group's checkbox, not the whole area. Uses `Mouse` (not `Click`)
        # because only it carries coordinates. Guarded on `checkable?` so a later
        # `checkable = false` stops it from toggling.
        on(Crysterm::Event::Mouse) do |e|
          next unless checkable? && e.action.down?
          # Hit-test the *painted* rect (`@lpos`), not layout coords
          # (`aleft`/`atop`): inside a scrolled container the painted rect is
          # shifted by the ancestor's scroll base, and dispatch hit-tests
          # `@lpos`. Guard on `no_top?` too — when the title row itself is
          # scrolled out of view, `lpos.yi` clips to the viewport top instead
          # of vanishing, which would otherwise toggle on the first visible
          # body row.
          if (lp = @lpos) && !lp.no_top? && e.y == lp.yi && e.x >= lp.xi && e.x < lp.xl
            toggle
            e.accept
          end
        end

        # A child added to an unchecked group must come up disabled. Children
        # are appended after construction, so reflect state on each as it's
        # adopted, not just on toggle. Only the disabling direction applies
        # here: on a *checked* group `apply_enabled` would instead run the
        # restore branch and force-enable every child the app itself disabled
        # (there was nothing for this adopt to restore).
        on(Crysterm::Event::ChildAdded) { apply_enabled if checkable? && !checked? }
      end

      private def label_text : String
        if checkable?
          mark = glyph(checked? ? Glyphs::Role::CheckboxChecked : Glyphs::Role::CheckboxUnchecked)
          "#{glyph(Glyphs::Role::CheckboxOpen)}#{mark}#{glyph(Glyphs::Role::CheckboxClose)} #{@title}".rstrip
        else
          @title
        end
      end

      private def update_label
        # The "nothing to show" state (empty title and not checkable) must CLEAR
        # any existing label, not skip — otherwise clearing the title or turning
        # off checkability at runtime leaves a stale border label. `remove_label`
        # is safe to call when no label is present.
        if @title.empty? && !checkable?
          remove_label
        else
          set_label label_text
        end
      end

      # Sets the checked state, refreshing the title marker and enabling or
      # disabling the contained children.
      def checked=(value : Bool) : Bool
        return value if value == @checked
        @checked = value
        update_label
        apply_enabled
        request_render
        value
      end

      def toggle
        self.checked = !checked?
      end

      # Checks / unchecks the group. The `AbstractButton` trio (`#check`,
      # `#uncheck`, `#toggle`) spelled for a `GroupBox`, which is a plain
      # `Widget` (as Qt makes `QGroupBox` a `QWidget`) and cannot inherit them.
      def check : Nil
        self.checked = true
      end

      # :ditto:
      def uncheck : Nil
        self.checked = false
      end

      # Toggles the flat (frameless) look, re-cascading so `GroupBox[flat]`
      # matches/unmatches.
      repaint_property flat, Bool, after: invalidate_css

      # Reflects the checked state onto children's `state`, so an unchecked
      # group renders disabled. The auto-created label is left untouched.
      #
      # When re-checking, only children *we* greyed out (currently `:disabled`)
      # are restored to `:normal`; a child in any other state — focus, hover,
      # selection — is left alone.
      private def apply_enabled
        return restore_disabled_children if checked?
        @children.each do |c|
          next if c.same? @label_widget
          c.state = :disabled
        end
      end

      # Restores children that were greyed out (currently `:disabled`) back to
      # `:normal`, leaving the auto-created label and any child in some other
      # state (focus, hover, selection) alone.
      private def restore_disabled_children
        @children.each do |c|
          next if c.same? @label_widget
          c.state = :normal if c.state.disabled?
        end
      end
    end
  end
end
