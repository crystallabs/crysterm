require "./box"

module Crysterm
  class Widget
    # Titled, bordered container, modeled after Qt's `QGroupBox`.
    #
    # Draws a border with the group `#title` as its label and holds arbitrary
    # child widgets. When `#checkable?` a `[x]`/`[ ]` marker is shown in the
    # title and toggling it enables/disables the contained children (Qt greys out
    # a checkable group's contents when unchecked).
    #
    # ```
    # gb = Widget::GroupBox.new parent: screen, title: "Options", width: 30, height: 8
    # Widget::CheckBox.new parent: gb, top: 0, content: "Wrap"
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![GroupBox screenshot](../../examples/widget/group_box/group_box-capture.png)
    # <!-- /widget-examples:capture -->
    class GroupBox < Box
      property title : String = ""

      # Whether the group has a checkable title that enables/disables its
      # contents (Qt's `QGroupBox#checkable`).
      property? checkable : Bool = false

      # Checked state of a `#checkable?` group; when false the children render
      # disabled.
      getter? checked : Bool = true

      def initialize(title = "", checkable = false, checked = true, **box)
        @title = title
        @checkable = checkable
        @checked = checked

        super **box

        # A titled border is the default look; it now comes from the CSS theme
        # (`GroupBox { border: solid }`) so it stays overridable by author CSS.
        update_label

        # `GroupBox::title { … }` styles the title — which is the auto-created label
        # child (`#set_label`, snapshotting `style.label` at creation), so push the
        # computed `title` sub-style onto it each frame after the cascade. Guarded
        # by `same?`, so it's a no-op (and the label keeps its default style) unless
        # a `::title` rule matched. See `Widget::TabWidget#sync_tab_style`.
        on(::Crysterm::Event::PreRender) do
          t = style.title
          @_label.try { |lbl| lbl.styles.normal = t } unless t.same?(style)
        end

        if checkable?
          # Toggle only when the *title* row is clicked (Qt toggles via the group's
          # checkbox, not the whole area). Toggling on any click in the group made
          # stray clicks near the controls disable everything. Uses `Mouse` (not
          # `Click`) because only it carries coordinates.
          on(Crysterm::Event::Mouse) do |e|
            next unless e.action.down?
            # Any click on the title (top-border) row toggles, like clicking a
            # group-box's title checkbox. Restricting it to the whole row keeps it
            # easy to hit while still not toggling on clicks down in the content.
            if e.y == atop && e.x >= aleft && e.x < aleft + awidth
              toggle
              e.accept
            end
          end

          # A child added to an unchecked group must come up disabled. Children are
          # appended by the caller *after* construction, so reflect the state onto
          # each one as it is adopted (not just on toggle).
          on(Crysterm::Event::Adopt) { apply_enabled }
        end
      end

      private def label_text : String
        if checkable?
          "#{checked? ? "[x]" : "[ ]"} #{@title}".rstrip
        else
          @title
        end
      end

      private def update_label
        set_label label_text unless @title.empty? && !checkable?
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

      # Reflects the checked state onto the children's `state`, so an unchecked
      # group renders its contents with the `disabled` style. The auto-created
      # label is left untouched.
      private def apply_enabled
        @children.each do |c|
          next if c.same? @_label
          c.state = checked? ? :normal : :disabled
        end
      end
    end
  end
end
