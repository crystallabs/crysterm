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
      # `#apply_substyle`, used by the `PreRender` handler below.
      include Mixin::SubStyle

      getter title : String = ""

      # Updates the stored title and the rendered border label at runtime. A
      # plain `property` left the label a construction-time snapshot, so
      # `gb.title = "…"` never changed anything on screen.
      def title=(value : String) : String
        @title = value
        update_label
        request_render
        value
      end

      # Whether the group has a checkable title that enables/disables its
      # contents (Qt's `QGroupBox#checkable`).
      getter? checkable : Bool = false

      # Enabling checkability at runtime must also add the `[x]` marker and wire
      # the title-row click/adopt handlers, which construction only did when
      # `checkable?` was already set.
      def checkable=(value : Bool) : Bool
        return value if value == @checkable
        @checkable = value
        update_label
        if value
          install_checkable_handlers
          apply_enabled
        else
          # No longer checkable ⇒ the "disabled because unchecked" reason is
          # gone, and there's no checkbox left to toggle back on. Restore any
          # children we greyed out so the contents stay usable (Qt re-enables a
          # group's children when it becomes non-checkable).
          restore_disabled_children
        end
        request_render
        value
      end

      # Guards `#install_checkable_handlers` against double-registration when
      # `checkable=` is toggled more than once.
      @checkable_wired = false

      # Memo backing the `PreRender` `::title` sub-style push: the last
      # `style.title` object seen and the border-stripped copy derived from it.
      # Rebuilt only when `style.title` returns a different object.
      @_title_style_src : ::Crysterm::Style?
      @_title_style_copy : ::Crysterm::Style?

      # Checked state of a `#checkable?` group; when false the children render
      # disabled.
      getter? checked : Bool = true

      # The `glyph_key` the baked title marker was built from; the `PreRender`
      # handler rebuilds the label when it moves.
      @_label_glyph_key : {String?, Glyphs::Tier, UInt64}?

      # Whether the group is *flat* — drawn without its frame (Qt's
      # `QGroupBox#flat`). Surfaced as the `[flat]` attribute; the theme strips
      # the default border via `GroupBox[flat]`, and Qt's `:flat` targets it.
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

        # `GroupBox::title { … }` styles the title — the auto-created label child
        # (`#set_label`, snapshotting `style.label` at creation) — so push the
        # computed `title` sub-style onto it each frame after the cascade.
        # Guarded by `same?`: no-op unless a `::title` rule matched. See
        # `Widget::TabWidget#sync_tab_style`.
        on(::Crysterm::Event::PreRender) do
          # The checkable marker is baked into the label at `update_label`
          # time, so a later glyph-tier change (a retheme via `Glyphs.set`, or
          # the screen's post-probe auto tier upgrade — widgets are built
          # before `Window#exec` probes) would leave it stale. Rebuild when
          # the resolved tier/registry generation moves.
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
            # box around the title text. Strip it on an own copy, as
            # `Menu#render_style_for` does for its separator rule (GroupBox-specific,
            # so done here rather than via `apply_substyle`).
            #
            # Cache the stripped copy: the cascade replaces the `::title`
            # sub-`Style` object on recompute (never mutates it), so refresh the
            # copy only when `style.title` returns a different object. Steady
            # state reuses it instead of duplicating a `Style` per frame.
            unless t.same?(@_title_style_src)
              @_title_style_src = t
              c = t.dup
              c.border = false
              @_title_style_copy = c
            end
            if c = @_title_style_copy
              @_label.try(&.styles.normal = c)
            end
          end
        end

        install_checkable_handlers if checkable?
      end

      # Wires the title-row toggle-click and the child-adopt reflect handlers.
      # Extracted so `checkable=` can install them when checkability is enabled
      # after construction; idempotent via `@checkable_wired`.
      private def install_checkable_handlers : Nil
        return if @checkable_wired
        @checkable_wired = true

        # Toggle only when the *title* row is clicked (Qt toggles via the group's
        # checkbox, not the whole area) — toggling on any click made stray clicks
        # near the controls disable everything. Uses `Mouse` (not `Click`)
        # because only it carries coordinates. Guarded on `checkable?` so a later
        # `checkable = false` stops it from toggling.
        on(Crysterm::Event::Mouse) do |e|
          next unless checkable? && e.action.down?
          if e.y == atop && e.x >= aleft && e.x < aleft + awidth
            toggle
            e.accept
          end
        end

        # A child added to an unchecked group must come up disabled. Children
        # are appended after construction, so reflect state on each as it's
        # adopted, not just on toggle.
        on(Crysterm::Event::Adopt) { apply_enabled if checkable? }
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

      # Toggles the flat (frameless) look, re-cascading so `GroupBox[flat]`
      # matches/unmatches (the shared CSS-toggle setter, `Box`).
      css_toggle_setter flat

      # Reflects the checked state onto children's `state`, so an unchecked
      # group renders disabled. The auto-created label is left untouched.
      #
      # When re-checking, only children *we* greyed out (currently `:disabled`)
      # are restored to `:normal`; a child in any other state — focus, hover,
      # selection — is left alone.
      private def apply_enabled
        # Re-checking restores exactly what `#restore_disabled_children` does;
        # only the unchecked case (grey the children out) is unique here.
        return restore_disabled_children if checked?
        @children.each do |c|
          next if c.same? @_label
          c.state = :disabled
        end
      end

      # Restores children that we previously greyed out (currently `:disabled`)
      # back to `:normal`, leaving the auto-created label and any child in some
      # other state (focus, hover, selection) alone. Used when checkability is
      # turned off, where `#apply_enabled` can't help (it would re-disable an
      # unchecked group's children).
      private def restore_disabled_children
        @children.each do |c|
          next if c.same? @_label
          c.state = :normal if c.state.disabled?
        end
      end
    end
  end
end
