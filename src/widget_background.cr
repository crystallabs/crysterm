module Crysterm
  class Widget
    # `style.background_image` support: an internal `Widget::Media` layer painted
    # *behind* this widget's content.
    #
    # The layer is a real (but chrome) `Media` child, so it inherits the whole
    # media lifecycle — decode/scale, cell-pixel detection, move/resize tracking,
    # erase-on-hide/destroy — for free. It is `#layout_excluded?` (never arranged
    # or rendered by the normal child pass) and instead rendered explicitly from
    # `_render` *before* the content, so it sits underneath.
    #
    # Backend selection reuses `Media.resolve(Content::Background)` (and thus the
    # `image.exclude` config). Two backend families render a background:
    #
    # * **Kitty** (`Media::Graphics`) — true pixels drawn *under* the cell grid
    #   (negative `z=`). The image is a terminal layer, so cells stay untouched
    #   and a default-background cell lets it show through (binary visibility).
    # * **Cells** (`Media::Glyph`/`Ansi`) — the image is painted *into* the window
    #   buffer. `_render` skips its empty (no-glyph) content cells so those keep
    #   the image, while text cells draw over it (and `style.alpha` grades them).
    #
    # The host doesn't branch on the backend except to mark a Kitty layer as a
    # background (`z=-1`); the Cells case is distinguished in `_render` by the
    # layer being a `Media::Cells` (see `#background_paints_cells?`).

    # Whether this widget is internal chrome that the layout engines must neither
    # arrange (measure/place) nor render in the normal child pass. The background
    # layer sets this; it is rendered out-of-band from `_render` instead.
    getter? layout_excluded = false

    # :ditto: — a runtime `false → true` flip also clears the subtree's
    # last-rendered rects (mirroring `Layout#skip_subtree`): every engine
    # early-returns on an excluded child without touching its `lpos`, so the
    # widget would stop painting while `Window#widget_at` — which hit-tests
    # every widget independently against its own `lpos` — kept routing
    # clicks/hovers to it (and its descendants) at the stale rects. Chrome that
    # renders out-of-band (the background layer) immediately refreshes its own
    # `lpos`, so the clear is harmless there.
    def layout_excluded=(value : Bool) : Bool
      if value != @layout_excluded
        clear_subtree_lpos self if value
        # Either flip changes what the child pass paints, invisibly to the
        # tracked geometry setters — flag damage so the optimized render
        # repaints the area (and, on re-inclusion, renders this subtree again).
        mark_dirty
      end
      @layout_excluded = value
    end

    # Clears the last-rendered rect of *el*'s whole subtree (the widget-side
    # analog of `Layout#skip_subtree`). Explicit recursion, allocation-free.
    # Shared: also called from `Widget#_render`'s early-return paths, whose
    # callers filter out `layout_excluded?` chrome (the same way `skip_subtree`'s
    # callers do — such chrome renders out-of-band with its own live `lpos`).
    protected def clear_subtree_lpos(el : Widget) : Nil
      el.lpos = nil
      el.children.each { |c| clear_subtree_lpos c }
    end

    # The internal `Widget::Media` layer rendering `style.background_image`, or
    # `nil` when no image is set / no background-capable backend is available.
    getter background_media : Media::Base?

    # Path currently loaded into `@background_media`, to detect URL changes.
    @background_url : String?

    # Reconciles the background-image layer with `style.background_image` and
    # renders it. Called once per frame from `_render`, *before* the content is
    # drawn. Creates the layer on first use, reloads it on a URL change, and tears
    # it down when the property is cleared (or no capable backend exists).
    protected def update_background_media : Nil
      src = style.background_image
      if src && (bg = ensure_background_media(src))
        sync_background_url bg, src
        # Re-assert the fit each frame so a `background-size` change after the
        # layer exists actually takes effect. `Media#fit=` only drops the sample
        # cache when the value genuinely changed, so an unchanged fit is cheap.
        bg.fit = background_fit
        bg.render
      elsif bg = @background_media
        bg.destroy # fires Event::Destroy → the backend erases its image
        @background_media = nil
        @background_url = nil
      end
    end

    # Whether the active background layer paints into the cell buffer
    # (`Media::Cells`) rather than a separate terminal-graphics layer (Kitty).
    # `_render` uses this to leave the layer's empty cells showing the image
    # instead of overwriting them with the widget's own fill.
    def background_paints_cells? : Bool
      @background_media.is_a?(Media::Cells)
    end

    # The backend `Media.resolve` picks for a background on this terminal
    # (Kitty when available, else the cell-grid fallback), or `nil` when this
    # widget has no window yet.
    private def background_backend : Media::Type?
      return nil unless s = window?
      Media.resolve Media::Content::Background, s.tput
    end

    # Lazily builds the background `Media` child for the resolved backend, pinned
    # to this widget's content box and made `fixed` + `layout_excluded`. Returns
    # `nil` when no background-capable backend is available.
    protected def ensure_background_media(src : String) : Media::Base?
      @background_media ||= begin
        type = background_backend || return nil
        m = Media.new(
          type: type,
          file: src,
          parent: self,
          top: 0, left: 0, right: 0, bottom: 0,
          fit: background_fit,
        )
        m.fixed = true
        m.layout_excluded = true
        # Kitty: place the image under text (negative `z=`).
        m.background = true if m.is_a?(Media::Kitty)
        @background_url = src
        m
      end
    end

    # Reloads the layer when the image path changes (cheaper than recreating the
    # widget; `Media#load` resets the backend's caches and re-renders).
    protected def sync_background_url(bg : Media::Base, src : String) : Nil
      return if @background_url == src
      @background_url = src
      bg.load src
    end

    # Maps the CSS `background-size` onto the media `Fit`. `Auto` (natural size)
    # has no `Fit` analog; it falls back to `Contain` (no cropping).
    private def background_fit : Media::Fit
      case style.background_size
      in .cover?   then Media::Fit::Cover
      in .contain? then Media::Fit::Contain
      in .stretch? then Media::Fit::Stretch
      in .auto?    then Media::Fit::Contain
      end
    end
  end
end
