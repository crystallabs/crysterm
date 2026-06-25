module Crysterm
  class Widget
    # `style.background_image` support: an internal `Widget::Media` layer painted
    # *behind* this widget's content.
    #
    # The layer is realized as a real (but chrome) `Media` child so it inherits
    # the whole media lifecycle — decode/scale, terminal cell-pixel detection,
    # move/resize tracking, and erase-on-hide/destroy — for free. It is
    # `#layout_excluded?` (never arranged or rendered by the normal child pass)
    # and instead rendered explicitly from `_render` *before* the content, so it
    # sits underneath.
    #
    # Backend selection reuses `Media.resolve(Content::Background)` (and thus the
    # `image.exclude` config): today only the Kitty graphics layer can draw true
    # pixels *under* the cell grid (negative `z=`), so a non-Kitty resolution is
    # treated as "no background layer" and the property simply has no visible
    # effect. The cell-grid backends (`Glyph`/`Ansi`) need the content loop to
    # leave their painted cells alone, which is a separate change.

    # Whether this widget is internal chrome that the layout engines must neither
    # arrange (measure/place) nor render in the normal child pass. The background
    # layer sets this; it is rendered out-of-band from `_render` instead.
    property? layout_excluded = false

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
        bg.render
      elsif bg = @background_media
        bg.destroy # fires Event::Destroy → the backend erases its image
        @background_media = nil
        @background_url = nil
      end
    end

    # The backend `Media.resolve` picks for a background on this terminal, or
    # `nil` when none can render one (only the Kitty graphics layer can sit under
    # text today; see the file header).
    private def background_backend : Media::Type?
      return nil unless s = screen?
      type = Media.resolve Media::Content::Background, s.tput
      type.kitty? ? type : nil
    end

    # Lazily builds the background `Media` child for the resolved backend, pinned
    # to this widget's content box (`top/left/right/bottom: 0`) and made `fixed`
    # + `layout_excluded`. Returns `nil` when no background-capable backend is
    # available (the property then has no visible effect).
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
