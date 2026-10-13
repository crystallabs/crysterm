module Crysterm
  class Widget
    class Menu
      # === Tear-off (detachable) menus ===
      #
      # GNOME 2's detachable menus, Qt's `QMenu#tearOffEnabled`. With the
      # feature on — the `menu.tear_off` option, or `#tear_off_enabled=` on one
      # menu — every pop-up menu and submenu carries a grab strip in the middle
      # of its top border row and another in the middle of its bottom one
      # (`Glyphs::Role::TearOffHandle`, `⠿⠿⠿`), so the menu can be grabbed at
      # either end. A theme that draws the menu's border already has those rows;
      # one that gives the menu no border (qdarkstyle's `QMenu { border: 0 }`)
      # gets a one-cell top and bottom border forced for the strips, and nothing
      # else. The two strips are the same strip on two edges: one geometry
      # (`#tear_off_strip_top`, `#tear_off_strip_left`) queried per edge, and
      # either one's drag or click does the same.
      #
      # Dragging a strip tears the menu off: a *torn-off menu* — Qt's
      # `QTornOffMenu` — is a new `Menu` on the same window holding the SAME
      # `Action` objects as the original, so checks, enabled states and texts
      # stay in step on both and an entry fired on either does the same thing.
      # It appears where the original is, follows the pointer for the rest of
      # the drag — keeping the point grabbed under the pointer, so a copy torn
      # by the bottom strip hangs from it as one torn by the top strip hangs
      # below it — and stays where the button is released; a click on a strip
      # without any motion tears the menu off in place, as Qt's tear-off item
      # tears on a click. Tearing off dismisses the original menu chain the way
      # a leaf activation does (a `MenuBar` deactivates and focus returns to the
      # central area) — at once, on the motion that tears the copy off, as Qt's
      # menu hides as soon as its torn-off menu shows, the drag carrying on in
      # the copy's strip (`Window#hand_over_drag`); the originals are otherwise
      # untouched, and still show the entries in the normal menus.
      #
      # A torn-off menu is a persistent, non-modal palette: an outside click
      # does not dismiss it, firing one of its entries leaves it up (a leaf
      # fired inside one of its submenus closes that submenu chain back to it),
      # and Escape takes the keyboard back to the window's central area rather
      # than closing it. Its own strips move it (a reposition drag), and the
      # close mark at the right end of its top row (`Glyphs::Role::WindowClose`,
      # `⊠`) destroys it. A press anywhere on it brings it to the front. It
      # takes keys once focused — a click on a row focuses it — and, like a
      # `MenuBar`, it sits off the Tab chain and in the F6 region ring. It
      # outlives the option without showing past it: turning the feature off —
      # the option, or `#tear_off_enabled=` on the menu it was torn off or on
      # itself — hides it (Qt's `setTearOffEnabled(false)` hides the torn-off
      # menu), out of the focus, the input and the F6 ring, and turning it on
      # again shows it where it was, with the same actions.
      #
      # The highlight — and the status tip it put up — leaves a torn-off menu
      # with the focus (a click on a pane, Tab, Escape) and with the pointer
      # when that leaves its chain with no submenu open, as Qt's `QMenu` drops
      # its active action on a leave event; a hidden or closed one clears its
      # tip as any menu does.
      # While the menu it was torn off lives, the torn-off menu follows the
      # actions added to or removed from it (Qt's `syncWithMenu`); a submenu is
      # rebuilt on every open, so a copy torn off a submenu keeps the entries it
      # was torn with. Its status tips go where the original chain's went — to
      # the root menu it was torn off, so a `MenuBar` and its `MainWindow` keep
      # showing them — while that root lives (`menu/tips.cr`).
      #
      # ```
      # Crysterm::Config.menu_tear_off = true # every menu, from now on
      # menu.tear_off_enabled = false         # but not this one
      # Widget::Menu.torn_off_menus(window).each &.close_torn_off
      # ```

      # Width in cells of the grab strip: a few repeated glyphs, enough to find
      # with the pointer and to read as "grab here", narrow enough to sit between
      # a title at the left and the close mark at the right.
      TEAR_OFF_HANDLE_WIDTH = 3

      # The per-menu override of the `menu.tear_off` option: `nil` (the default)
      # follows the option, read live, so a change applies to the menu as it is.
      @tear_off_enabled : Bool? = nil

      # Whether this menu shows the tear-off strip (Qt's `QMenu#isTearOffEnabled`):
      # its own `#tear_off_enabled=` when set, else the `menu.tear_off` option.
      def tear_off_enabled? : Bool
        v = @tear_off_enabled
        v.nil? ? ::Crysterm::Config.menu_tear_off : v
      end

      # Overrides the `menu.tear_off` option for this menu (Qt's
      # `QMenu#setTearOffEnabled`); `nil` follows the option again. Submenus
      # opened from this menu inherit the override, as does a menu torn off it.
      #
      # On a menu with torn-off copies the override goes to the copies as well,
      # and on a torn-off menu it shows or hides the menu (`#sync_torn_visibility`).
      def tear_off_enabled=(value : Bool?) : Bool?
        @tear_off_enabled = value
        update!
        if torn_off?
          sync_torn_visibility
        elsif win = window?
          Menu.torn_off_menus(win).each do |t|
            t.tear_off_enabled = value if t.torn_source.same?(self)
          end
        end
        value
      end

      # Whether this menu is a torn-off copy (Qt's `QTornOffMenu`).
      getter? torn_off : Bool = false

      # The menu this one was torn off, while that menu lives (Qt's
      # `causedMenu`); `nil` for a menu that is not torn off, or whose original
      # is gone — a submenu is destroyed when its chain closes.
      getter torn_source : Menu?

      # The root of the chain this menu was torn off, while it lives: where a
      # torn-off menu's status tips go (`#tip_root`), as Qt's `QTornOffMenu`
      # keeps the caused stack up to the menu bar for its `topCausedWidget`. A
      # submenu's root outlives the submenu, so a copy torn off one still
      # reports to the bar after its source is gone.
      @torn_tip_root : Menu?

      # The torn-off menus on *window*: its top-level `Menu` children that are
      # `#torn_off?`, for an application to find and close
      # (`each &.close_torn_off`).
      def self.torn_off_menus(window : Window) : Array(Menu)
        window.children.compact_map { |w| w.as?(Menu).try { |m| m if m.torn_off? } }
      end

      # The edges that carry a grab strip, in building (and hit-list) order.
      TEAR_OFF_EDGES = {::Crysterm::Side::Top, ::Crysterm::Side::Bottom}

      # The grab strips on the top and bottom border rows, and the close mark a
      # torn-off menu adds beside the top one: chrome children glued to the
      # border rows the way a `#title` label is (`Widget#set_label`), created at
      # the first paint that wants them.
      @tear_off_handle_top : TearOffHandle?
      @tear_off_handle_bottom : TearOffHandle?
      @tear_off_close : Box?

      # The glyph the close mark was last built from: a steady frame compares a
      # `Char` instead of building its text anew to find it unchanged
      # (`#place_tear_off_close`; a strip keeps its own, `TearOffHandle#glyph`).
      @tear_off_close_glyph : Char?

      # The copy torn off by the drag of this menu's strip now under way, from the
      # first motion (or the click) until the original chain is closed.
      @tear_off_pending : Menu?

      # Whether this torn-off menu is hidden because tear-off was turned off for
      # it, to be shown again when it is turned back on (`#sync_torn_visibility`).
      # A torn-off menu the program hid itself is not marked, and stays hidden.
      getter? torn_suppressed = false

      # Whether the pointer was last seen over this torn-off menu's chain, so
      # its leaving is a transition (`#torn_pointer_moved`).
      @torn_pointer_inside = false

      # A torn-off menu's subscriptions on its original and on the window, ended
      # with it.
      @torn_subs : ::Crysterm::Subscriptions?

      # The top and bottom border `#ensure_tear_off_border` forced, for
      # `#restore_tear_off_border`: the style written to, the border left on it,
      # its top and bottom widths before (or the frozen border it replaced).
      @tear_off_forced_style : Style?
      @tear_off_forced_border : Border?
      @tear_off_forced_replaced : Border?
      @tear_off_forced_top : Int32 = 0
      @tear_off_forced_bottom : Int32 = 0

      # Whether the `menu.tear_off` watcher below is installed.
      @@tear_off_watched = false

      # Repaints every menu on every window when `menu.tear_off` changes, so an
      # open menu gains or loses its strip at once rather than on its next open —
      # as `Widget::Media.watch_config` rebuilds the media for a backend change —
      # and hides or shows the torn-off menus again (`#sync_torn_visibility`).
      # Installed from the first menu paint; the option is read live by
      # `#tear_off_enabled?`, so the watcher only has to ask for the frame.
      protected def self.watch_tear_off_config : Nil
        return if @@tear_off_watched
        @@tear_off_watched = true
        ::Crysterm::Config.on_change("menu.tear_off") do
          ::Crysterm::Window.instances.each do |window|
            window.each_descendant { |w| w.update! if w.is_a?(Menu) }
            torn_off_menus(window).each &.sync_torn_visibility
          end
        end
      end

      # Shows or hides this torn-off menu as `#tear_off_enabled?` now says: off,
      # a shown menu hides — its submenu closed, its highlight and status tip
      # cleared, the keyboard handed back to the central area, so a hidden
      # palette holds no focus and, invisible, takes no input and no F6 stop —
      # and is marked `#torn_suppressed?`; on, a menu so marked shows again at
      # the place and stacking it had. A no-op on a menu that is not torn off.
      protected def sync_torn_visibility : Nil
        return unless torn_off?
        if tear_off_enabled?
          return unless @torn_suppressed
          @torn_suppressed = false
          show
          update!
        else
          return if @torn_suppressed || !visible?
          @torn_suppressed = true
          drop_torn_highlight
          if (win = window?) && (f = win.focused) && chain_holds?(f)
            win.focus_central
          end
          hide
        end
      end

      # Tears this menu off (Qt's `QMenu#showTearOffMenu`): the torn-off copy is
      # a new `Menu` on this menu's window, with this menu's actions, inline style
      # and row cap, sized like it and placed over it, in front of everything.
      # The user's drag then moves it (`#tear_off_drag_to`); a program may call
      # this directly and `#move` the result. This menu is left as it is — the
      # strip's gesture closes its chain separately (`#tear_off_finished`).
      def tear_off : Menu
        torn = Menu.new(window: window, style: assigned_inline_style.try(&.dup))
        torn.adopt_torn_off self
        # One row rebuild for the whole copy (see `#begin_update`).
        torn.batch_update { @actions.each { |a| torn << a } }
        # Into the tree and through the cascade now, as `#open_submenu` does for
        # a fresh child, so the fit below sees the themed box model.
        window.append torn
        window.restyle_structural torn
        window.apply_stylesheet
        torn.fit_to_content
        # Over this menu, clamped on-window; `Overlay.place_child` owns the
        # absolute→window-local conversion. A never-rendered menu has no place to
        # copy, and the copy keeps the default origin.
        if lp = last_rendered_position?
          Overlay.place_child(torn, {lp.xi, lp.yi, 0, 0},
            {torn.width_spec.as?(Int) || 1, torn.height_spec.as?(Int) || 1},
            [Overlay::Side::At], point: {lp.xi, lp.yi})
        end
        torn.to_front
        torn.update!
        torn
      end

      # Destroys this torn-off menu (Qt's `QMenu#hideTearOffMenu`, whose torn
      # menu deletes itself on close): off the window, its action watchers
      # dropped. A no-op on a menu that is not torn off.
      def close_torn_off : Nil
        return unless torn_off?
        Widget.destroy_satellite self
      end

      # Makes this fresh menu the torn-off copy of *source*: marked, carrying the
      # source's title, row cap and tear-off override, off the Tab chain and in
      # the F6 region ring like a `MenuBar` (that is what lets Escape's
      # `Window#focus_central` find the central area from it), following the
      # source's later action changes, and raised to the front by any press on
      # it. `#tear_off` calls this before the actions are copied.
      protected def adopt_torn_off(source : Menu) : Nil
        @torn_off = true
        @torn_source = source
        @tear_off_enabled = source.@tear_off_enabled
        self.max_visible_rows = source.max_visible_rows
        self.title = source.title unless source.title.empty?
        self.focus_policy = FocusPolicy::Click
        @region_focusable = true
        subs = @torn_subs = ::Crysterm::Subscriptions.new
        # Qt's `QTornOffMenu#syncWithMenu`: an action added to or removed from
        # the original shows up here too. The original emits `ItemsChanged` on
        # every row rebuild, so the copy compares first and re-adopts the set
        # only when it actually differs.
        subs.on(source, ::Crysterm::Event::ItemsChanged) { sync_torn_actions }
        subs.on(source, ::Crysterm::Event::Destroy) { @torn_source = nil }
        root = @torn_tip_root = source.root_menu
        subs.on(root, ::Crysterm::Event::Destroy) { @torn_tip_root = nil }
        # A press anywhere on the torn-off menu brings it in front of whatever
        # was raised over it since; watched at the window, as its rows take the
        # press themselves. The press has to land *on* the menu — the window
        # hears every press, and one on a dialog drawn over the menu must not
        # lift the menu over the dialog.
        win = window
        subs.on(win, ::Crysterm::Event::Mouse) do |e|
          raise_torn_off if e.action.down? && covers?(win.widget_at(e.x, e.y))
          torn_pointer_moved e.x, e.y if e.action.move?
        end
      end

      # Whether *w* is in this menu or in its open submenu chain (submenus are
      # window children, not descendants, so `#covers?` alone misses them).
      private def chain_holds?(w : Widget) : Bool
        !!w.first_self_or_ancestor { |a| covers?(a) || a.as?(Menu).try(&.submenu_of?(self)) }
      end

      # The pointer moved to (*x*, *y*): on leaving this torn-off menu's chain
      # with no submenu open, the highlight goes, as `QMenu#leaveEvent` drops
      # the active action — and with it the status tip it put in the bar.
      private def torn_pointer_moved(x : Int32, y : Int32) : Nil
        inside = visible? && in_chain?(x, y)
        left = @torn_pointer_inside && !inside
        @torn_pointer_inside = inside
        drop_torn_highlight if left && @submenu_open.nil?
      end

      # Focus moved from somewhere in this menu's chain to *next_focused*
      # (`nil` for no widget; from `menu/tips.cr`, on the chain's root): on a
      # torn-off menu, focus that left the chain takes the highlight, the open
      # submenu and the status tip with it — Qt's torn-off menu clears its
      # status tip when it stops being active. A no-op on any other menu, whose
      # chain closes when it loses the keyboard.
      protected def chain_focus_left(next_focused : Widget?) : Nil
        return unless torn_off?
        return if next_focused && chain_holds?(next_focused)
        drop_torn_highlight
      end

      # Clears this torn-off menu's highlight: an open submenu closes without
      # taking the focus back from where it went, and the leaving highlight
      # clears the status tip and the tooltip (`menu/tips.cr`).
      private def drop_torn_highlight : Nil
        close_submenu(refocus: false) if @submenu_open
        return unless @show_highlight
        @show_highlight = false
        highlight_changed
        update!
      end

      # Re-adopts the original's action set when it changed under the copy.
      private def sync_torn_actions : Nil
        return unless source = @torn_source
        return if @actions == source.actions
        self.actions = source.actions
      end

      # Brings the torn-off menu to the front, with its open submenu chain back in
      # front of it — a plain `#to_front` would bury a submenu that is a later
      # window child under the menu that opened it.
      private def raise_torn_off : Nil
        return if window.children.last?.same?(self) && @submenu_open.nil?
        to_front
        child = @submenu_open
        while child
          child.to_front
          child = child.@submenu_open
        end
      end

      # Escape on a torn-off menu (returns whether it consumed *e*): the menu
      # stays — it is closed by its close mark, not by a key — and the keyboard
      # goes back to the window's central area, as a `MenuBar`'s does when a
      # menu is dismissed; an open submenu closes and the highlight clears, as on
      # any menu's cancel.
      private def torn_off_escape(e) : Bool
        return false unless torn_off?
        close_submenu if @submenu_open
        @show_highlight = false
        highlight_changed # the highlight left (`menu/tips.cr`)
        update!
        window.focus_central
        e.accept
        true
      end

      # Grab offset of a strip drag, measured against this menu rather than the
      # strip: the copy (or the torn-off menu itself) keeps the grabbed point
      # under the pointer, so it appears exactly where the original was grabbed
      # — by its bottom strip as by its top one, the copy being the same size.
      protected def tear_off_grab_offset(x : Int32, y : Int32) : Tuple(Int32, Int32)
        drag_grab_offset x, y
      end

      # One motion of a strip drag. On a torn-off menu it is a reposition drag:
      # the menu follows the pointer. On any other menu the first motion tears
      # the copy off, over this menu, moves it under the pointer and hands the
      # drag to the copy's strip on the same edge (`Window#hand_over_drag`), so
      # its grab offset stays the one taken on this menu, which carries it to
      # the release — or, in two-click mode, to the dropping press — as a
      # reposition drag of the copy; the original's strip gets its `DragEnd`
      # there and then, closing the original chain at once (`#tear_off_finished`).
      protected def tear_off_drag_to(x : Int32, y : Int32, dx : Int32, dy : Int32) : Nil
        return drag_move_to(x, y, dx, dy) if torn_off?
        fresh = @tear_off_pending.nil?
        copy = @tear_off_pending ||= tear_off
        copy.drag_move_to x, y, dx, dy
        return unless fresh
        win = window
        if (sess = win.drag_session) && (h = sess.source.as?(TearOffHandle)) &&
           tear_off_handle?(h.edge).same?(h)
          win.hand_over_drag sess, copy.tear_off_handle!(h.edge)
        end
      end

      # The grab strip on *edge* (`Side::Top` or `Side::Bottom`), if built.
      def tear_off_handle?(edge : ::Crysterm::Side) : TearOffHandle?
        edge.bottom? ? @tear_off_handle_bottom : @tear_off_handle_top
      end

      private def set_tear_off_handle(edge : ::Crysterm::Side, handle : TearOffHandle?) : Nil
        if edge.bottom?
          @tear_off_handle_bottom = handle
        else
          @tear_off_handle_top = handle
        end
      end

      # The copy's grab strip on *edge*, built and placed now if no frame has
      # yet — a drag handed to it on the motion that tore the copy off comes
      # before its first paint.
      protected def tear_off_handle!(edge : ::Crysterm::Side) : TearOffHandle
        sync_tear_off_chrome
        tear_off_handle?(edge) || build_tear_off_handle(edge)
      end

      # A click on the strip with no motion in between: tears the menu off in
      # place (Qt's tear-off item tears on the click), then closes the chain as
      # a drag's release does. Nothing on a torn-off menu, whose strip only moves
      # it.
      protected def tear_off_clicked : Nil
        return if torn_off?
        @tear_off_pending ||= tear_off
        tear_off_finished
      end

      # The strip's gesture ended for this menu (the drag handed to the copy on
      # its first motion, the click, or a drag cancelled before it moved).
      # With a copy torn off, the original chain is dismissed the way a leaf
      # activation dismisses it — `#close_chain`, then the root's
      # `#chain_activated_handler`, so a `MenuBar` deactivates and hands focus to
      # the central area (Qt's `hideUpToMenuBar`). The copy stays wherever the
      # gesture left it. A reposition drag of a torn-off menu ends nothing.
      protected def tear_off_finished : Nil
        return unless @tear_off_pending
        @tear_off_pending = nil
        root = root_menu
        root.close_chain
        root.chain_activated_handler.try &.call
      end

      # Whether this menu draws the tear-off chrome: a torn-off menu always
      # (its strip moves it and its close mark closes it), any other while the
      # feature is on for it.
      private def tear_off_chrome? : Bool
        torn_off? || tear_off_enabled?
      end

      # From `#paint`: builds, places and colors the strips (and a torn-off
      # menu's close mark) when the chrome is wanted, and drops the strips of a
      # menu the feature was turned off under — the chrome follows the option
      # and the override frame by frame, as the rows follow their theme. The box
      # is re-fitted to the forced border rows first (`#autosize`, a no-op once
      # it fits), so the bottom strip lands on the bottom row of this frame.
      private def sync_tear_off_chrome : Nil
        Menu.watch_tear_off_config
        if tear_off_chrome?
          ensure_tear_off_border
          autosize
          TEAR_OFF_EDGES.each do |edge|
            place_tear_off_handle(tear_off_handle?(edge) || build_tear_off_handle(edge))
          end
          if torn_off?
            close = @tear_off_close ||= build_tear_off_close
            place_tear_off_close close
          end
        else
          restore_tear_off_border
          TEAR_OFF_EDGES.each do |edge|
            next unless handle = tear_off_handle?(edge)
            set_tear_off_handle edge, nil
            handle.destroy
          end
        end
      end

      # Gives the menu a top and a bottom border row for the strips when its
      # resolved style has none (a theme's `Menu { border: 0 }`, an inline
      # `border: false`): those sides alone, each only where it is missing, set in place on the backing per-state style the way
      # `#strip_item_box_model` zeroes the rows' — the cascade mints fresh style
      # objects on every re-run, so this runs again from the next paint. A menu
      # that already draws a top or bottom border, from its theme or the unstyled
      # floor, reuses that row as is. Also run from `#fit_to_content`, so a pop-up is
      # sized with the row before its first frame.
      #
      # The write in place touches this menu alone. The style it lands on is
      # the menu's own: under a stylesheet a fresh dup of its pristine
      # snapshot, given its own `Border` by every path that fills one in
      # (`Style#dup`, the inline fold, a parsed `border:`), never a theme's or
      # a sibling's object; without one the inline style `Menu.new` dups (as
      # `#tear_off` and `#open_submenu` dup theirs again), or its
      # `Styles.default` deep dup. The rows' styles `#strip_item_box_model`
      # zeroes are owned the same way — each row's own cascade result. A
      # frozen `Border` (`Border::ZERO`, assigned whole) is replaced instead.
      #
      # Under a stylesheet the next cascade replaces the object written to, so
      # the forced row goes with it; but a menu the cascade does not style
      # (no stylesheet, or no rule matches) writes into its inline style, which
      # outlives every cascade. So the write is remembered — the style, the
      # border it left there and what it replaced — and `#restore_tear_off_border`
      # undoes it when the strip is no longer wanted.
      private def ensure_tear_off_border : Nil
        bv = style.border_view
        has_top = bv.top > 0
        has_bottom = bv.bottom > 0
        return if has_top && has_bottom
        st = state_style
        b = st.border
        @tear_off_forced_style = st
        @tear_off_forced_replaced = nil
        if b.frozen?
          @tear_off_forced_replaced = b
          @tear_off_forced_border = st.border = ::Crysterm::Border.from(
            {has_top ? b.top : 1, b.right, has_bottom ? b.bottom : 1, b.left}) # top, right, bottom, left
        else
          @tear_off_forced_top = b.top
          @tear_off_forced_bottom = b.bottom
          @tear_off_forced_border = b
          b.top = 1 unless has_top
          b.bottom = 1 unless has_bottom
        end
        # The insets are derived from the resolved style, and an in-place write
        # is invisible to damage tracking.
        invalidate_frame_style
        update!
      end

      # Gives back the top and bottom border `#ensure_tear_off_border` forced,
      # once the strips are no longer wanted: the original widths put back in place, or the
      # frozen `Border` that was replaced assigned again. Only while the forced
      # border is still the style's own (a cascade or a program that replaced it
      # since has already settled the matter), so a border the program has
      # changed meanwhile is not overwritten.
      private def restore_tear_off_border : Nil
        return unless st = @tear_off_forced_style
        forced = @tear_off_forced_border
        @tear_off_forced_style = nil
        @tear_off_forced_border = nil
        return unless forced && st.border.same?(forced)
        if replaced = @tear_off_forced_replaced
          st.border = replaced
        else
          forced.top = @tear_off_forced_top
          forced.bottom = @tear_off_forced_bottom
        end
        @tear_off_forced_replaced = nil
        invalidate_frame_style
        update!
      end

      # The texts come from the placement that follows every build
      # (`#sync_tear_off_chrome`), which sets them whenever the glyph differs
      # from the one last used — on a fresh box, always.
      private def build_tear_off_handle(edge : ::Crysterm::Side) : TearOffHandle
        handle = TearOffHandle.new(self, edge, parent: self,
          top: tear_off_strip_top(edge), left: tear_off_strip_left,
          height: 1, width: TEAR_OFF_HANDLE_WIDTH, style: Style.new)
        border_chrome handle
        set_tear_off_handle edge, handle
        handle
      end

      private def build_tear_off_close : Box
        @tear_off_close_glyph = nil
        close = Box.new(parent: self,
          top: -itop, right: 1 - iright, height: 1, width: 1, style: Style.new)
        border_chrome close
        close.on(::Crysterm::Event::Click) { close_torn_off }
        close
      end

      # Marks *box* as chrome on the border row, as `Widget#set_label` marks a
      # label: exempt from the scrollable-ancestor border clip, and never a
      # content slot for a layout engine.
      private def border_chrome(box : Box) : Nil
        box._is_label = true
        box.layout_chrome = true
      end

      # The strip's geometry, for either edge: the row of *edge*'s border in
      # the menu's child coordinates — the top row is `@child_base - itop`, as
      # `Widget#reposition_label` keeps a label there when the content scrolls,
      # and the bottom row is the menu's last, `aheight - 1` rows below it.
      private def tear_off_strip_top(edge : ::Crysterm::Side) : Int32
        top = @child_base - itop
        edge.bottom? ? top + Math.max(aheight - 1, 0) : top
      end

      # The strip's column in the menu's child coordinates: centered on the
      # menu's full width, the same for both edges.
      private def tear_off_strip_left : Int32
        Math.max((awidth - TEAR_OFF_HANDLE_WIDTH) // 2, 0) - ileft
      end

      # Centers a strip on its border row, re-reading the glyph (a tier switch,
      # `Glyphs.set`) and the menu's size (an auto-sized menu grows with its
      # rows) each frame; a change-guarded no-op on the steady frame, which
      # builds no text: the glyph is compared as a `Char`.
      private def place_tear_off_handle(handle : TearOffHandle) : Nil
        g = glyph(Glyphs::Role::TearOffHandle)
        unless g == handle.glyph
          handle.glyph = g
          handle.set_content g.to_s * TEAR_OFF_HANDLE_WIDTH
        end
        left = tear_off_strip_left
        handle.left = left unless handle.left == left
        pin_border_chrome handle, handle.edge
      end

      # Puts the close mark at the right end of the top border row, just inside
      # the corner, whatever the theme's side border and padding.
      private def place_tear_off_close(close : Box) : Nil
        g = glyph(Glyphs::Role::WindowClose)
        unless g == @tear_off_close_glyph
          @tear_off_close_glyph = g
          close.set_content g.to_s
        end
        right = 1 - iright
        close.right = right unless close.right == right
        pin_border_chrome close
      end

      # Keeps a border-row chrome box on *edge*'s border row
      # (`#tear_off_strip_top`), drawn in that border's colors on the menu's
      # surface, so it reads as part of the frame under any theme. The colors go
      # onto the box's backing style in place and are re-asserted each frame,
      # since a cascade resets them.
      private def pin_border_chrome(box : Box, edge : ::Crysterm::Side = ::Crysterm::Side::Top) : Nil
        top = tear_off_strip_top(edge)
        box.top = top unless box.top == top
        bv = style.border_view
        fg = (edge.bottom? ? bv.bottom_fg : bv.top_fg) || style.fg
        bg = style.bg
        st = box.state_style
        unless st.fg == fg && st.bg == bg
          st.fg = fg
          st.bg = bg
          box.update
        end
      end

      # From `#destroy`: ends a torn-off menu's subscriptions and forgets a copy
      # under construction.
      private def tear_off_destroyed : Nil
        @torn_subs.try &.off
        @torn_subs = nil
        @torn_source = nil
        @torn_tip_root = nil
        @tear_off_pending = nil
      end

      # A grab strip on a menu's top or bottom border row (`#edge`): a draggable
      # chrome box whose drag is the menu's tear-off (or, on a torn-off menu,
      # its move), the same on either edge. It uses
      # the standard reposition drag machinery (`Widget#draggable=`) and redirects
      # its two geometry hooks to the menu — the grab offset is measured against
      # the menu and each motion moves the torn-off copy — so there is no drag
      # ghost and a plain click still arrives as `Event::Click`. It never takes
      # keyboard focus (not keyable), and sits inside the menu's rectangle, so
      # the menu's modal grab counts a press on it as inside.
      class TearOffHandle < Box
        # The menu border this strip sits on: `Side::Top` or `Side::Bottom`.
        getter edge : ::Crysterm::Side

        # The glyph the strip's text was last built from (`Menu#place_tear_off_handle`).
        property glyph : Char?

        def initialize(@menu : Menu, @edge : ::Crysterm::Side = ::Crysterm::Side::Top, **box)
          super(**box)
          self.draggable = true
          on(::Crysterm::Event::Click) { @menu.tear_off_clicked }
          on(::Crysterm::Event::DragEnd) { @menu.tear_off_finished }
        end

        protected def drag_grab_offset(x : Int32, y : Int32) : Tuple(Int32, Int32)
          @menu.tear_off_grab_offset x, y
        end

        protected def drag_move_to(x : Int32, y : Int32, dx : Int32, dy : Int32) : Nil
          @menu.tear_off_drag_to x, y, dx, dy
        end
      end
    end
  end
end
