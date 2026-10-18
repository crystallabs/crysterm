module Crysterm
  class Widget
    class TextEdit
      # === Block images ===
      #
      # A block that is an image (`TextBlockFormat#image`, the Markdown
      # importer's `![alt](src)` paragraph) is drawn as a picture when
      # `#images_enabled?`: the layout reserves rows for it above the
      # block's own text row, and a `Widget::Media` child paints the picture
      # there. Qt lays an image out as an inline object of a `QTextLayout`
      # and paints it itself; on a cell grid the picture is a widget of its
      # own — Crysterm's `Media` family knows how each terminal draws one —
      # so the view owns a child per picture on screen, the way its
      # `background-image` layer is a child (`Widget#update_background_media`).
      #
      # Rows. A picture is drawn at its natural size, as Qt draws an inline
      # image at its pixel size: the image's pixel size (`Media.decode`, the
      # process-wide decode cache the child reads from too) over the
      # terminal's cell size in pixels (`Screen#cell_pixel_width`/`_height`,
      # probed at startup; `FALLBACK_CELL_PIXELS` when the terminal reports
      # none) is the cells it takes. Only a picture that does not fit is
      # shrunk, `Media::Fit::Contain`-style — by one factor, so its aspect
      # keeps — to the block's text width or to the row cap
      # (`#max_image_rows`, half the viewport by default), whichever asks
      # for more; a small icon is never blown up to the column. The rows are
      # margin rows (`RowMeta#margin`), which the caret steps over as it
      # steps over a block's top margin, so the picture adds no positions:
      # the block's text row — the picture glyph and the alt text — stays
      # below the picture as its caption, where the caret lands, and is what
      # a selection copies. An image whose file is missing or cannot be
      # decoded reserves nothing: the caption row stands alone, as the view
      # shows every image with images off.
      #
      # Children. On each frame (`#sync_block_images`, before the child pass
      # paints them) the view keeps one `Media` child per picture whose rows
      # meet the viewport, placed at the picture's document row: a child of
      # a scrollable widget is shifted by the scroll and clipped to the
      # viewport by `Widget#coords`, so a picture scrolls with the text and
      # a partly scrolled-out one is cut at the viewport's edge where the
      # backend paints cells (`Media::Cells`, which samples the whole box and
      # draws the visible slice). A terminal-graphics backend
      # (`Media::Graphics`: Kitty, Sixel, iTerm2) paints what the terminal
      # draws into the clipped rectangle, which would squeeze a half-visible
      # picture into the rows left, so such a child is hidden while its
      # picture is only partly in view and shown again once it is whole —
      # which the half-viewport cap makes possible for every picture. A
      # child whose picture left the viewport is destroyed; one is reused
      # for a picture with the same source wherever it lands, so a document
      # re-rendered from its source on every keystroke (a live preview) keeps
      # its pictures without re-decoding or re-transmitting them. The backend
      # is the one `Media.resolve` picks for the terminal and the
      # `media.backend` option; a run-time change of the option drops the
      # children (`#reset_resolved_media`, from `Media.rebuild_resolved`) and
      # the next frame builds them for the new backend.
      #
      # Sources. An image's name is resolved against the document's
      # `TextDocument#base_url`, as Qt resolves against `QTextDocument::baseUrl`.
      # A local file is decoded on the render fiber when the layout first
      # meets it (a stat and a cache hit on every later frame). An `http(s)`
      # URL is fetched on a fiber of its own instead, so a slow or dead
      # server never stalls the view: until it arrives the block shows its
      # caption alone, then the layout takes the picture in — a shift of the
      # rows below, as a browser's page shifts when its images arrive.
      #
      # No pictures. With `media.backend` at `None` (`Media.disabled?`) no
      # image is fetched, decoded or drawn: an image with a title
      # (`![alt](src "title")`, `TextImageFormat#title`) shows it in the
      # picture's place — the picture glyph and the title, muted, on margin
      # rows wrapped to the text width — over the caption row; one without
      # (or whose title is its alt text) is its caption row alone, the
      # picture glyph and the alt text, as with images off. A change of the
      # option into or out of `None` lays the images out again
      # (`#reset_resolved_media`).

      # The cell size in pixels (width, height) a picture is measured in
      # when the terminal reports none (`Screen#cell_pixel_width`/`_height`
      # are 0 — no `TIOCGWINSZ` pixel size, no XTWINOPS answer, a headless
      # window): a typical monospace cell, the same assumption
      # `Media::Graphics` draws with.
      FALLBACK_CELL_PIXELS = {10, 20}

      # The share of the viewport's rows a picture may take without
      # `#max_image_rows`: half.
      IMAGE_VIEWPORT_FRACTION = 2

      # Whether block images are drawn as pictures (default on; the
      # boolean counterpart of `#links_enabled?` for images). Off, an image
      # block is its text alone — the picture glyph and the alt text — and
      # the view holds no `Media` children.
      getter? images_enabled : Bool = true

      # :ditto:
      def images_enabled=(v : Bool) : Bool
        return v if @images_enabled == v
        @images_enabled = v
        invalidate_images
        v
      end

      # The most rows a picture takes; `nil` (the default) is half the
      # viewport's rows, at least one.
      getter max_image_rows : Int32?

      # :ditto:
      def max_image_rows=(rows : Int32?) : Int32?
        rows = Math.max(rows, 1) if rows
        return rows if @max_image_rows == rows
        @max_image_rows = rows
        invalidate_images
        rows
      end

      # A picture the layout reserved rows for: its first display row, its
      # rows and columns, the column its left edge sits at (the block's
      # decoration offset) and the resolved source the `Media` child loads.
      private record ImageSlot,
        row : Int32,
        rows : Int32,
        offset : Int32,
        cols : Int32,
        source : String

      # The pictures of the current layout, in document order (rebuilt by
      # `#rebuild_layout`).
      @image_slots = [] of ImageSlot

      # Whether the current layout laid out an image block with images on —
      # a picture, a title in its place, or a caption alone — so a change of
      # the media options must lay it out again (`#reset_resolved_media`).
      @image_blocks_laid_out = false

      # Natural pixel sizes by resolved source; `nil` is a source that could
      # not be read or decoded, kept so it is not retried every frame.
      # Emptied when the whole content is replaced, so a file rewritten on
      # disk is measured again.
      @image_sizes = {} of String => Tuple(Int32, Int32)?

      # Remote sources being fetched on their own fibers.
      @image_loading = Set(String).new

      # The `Media` children drawing the pictures in view.
      @block_images = [] of Media::Base

      # Bumped whenever the pictures' layout inputs change outside the
      # document — `#images_enabled`, `#max_image_rows`, a remote image's
      # size arriving — and recorded by `#rebuild_layout`, so
      # `#process_content`'s steady-frame test sees the change without a
      # document revision (which would also re-follow the caret).
      @images_revision = 0
      @images_laid_out = -1

      # The row cap `#rebuild_layout` last fitted the pictures to
      # (`#image_row_cap`): with no `#max_image_rows` it follows the viewport's
      # height, which a resize changes without touching the layout key (the
      # key is the width's) or the document.
      @image_cap_laid_out = -1

      # The cell size in pixels the pictures were last measured in
      # (`#image_cell_pixels`): a font or zoom change re-probes it
      # (`Screen#refresh_cell_geometry`) without a change of the key, the
      # document or the cap when the terminal keeps its cell count.
      @image_cells_laid_out = {0, 0}

      # Whether the pictures are laid out as their inputs stand now
      # (`#process_content`'s share of the steady-frame test): the revision,
      # and — for pictures that exist — the row cap and the cell size. A
      # document without a measurable picture is not relaid for a height
      # change.
      private def images_current? : Bool
        return false unless @images_laid_out == @images_revision
        return true if !@images_enabled || @image_slots.empty?
        @image_cap_laid_out == image_row_cap && @image_cells_laid_out == image_cell_pixels
      end

      # The terminal's cell size in pixels a picture is measured in: what
      # the screen probed, each axis the terminal left at 0 standing in from
      # `FALLBACK_CELL_PIXELS`.
      private def image_cell_pixels : Tuple(Int32, Int32)
        win = window?
        w = win.try(&.cell_pixel_width) || 0
        h = win.try(&.cell_pixel_height) || 0
        {w > 0 ? w : FALLBACK_CELL_PIXELS[0], h > 0 ? h : FALLBACK_CELL_PIXELS[1]}
      end

      # Whether *src* is fetched over the network rather than read from disk.
      private def remote_image?(src : String) : Bool
        src =~ /\Ahttps?:/i ? true : false
      end

      # Drops the measured sizes of the local files, after a whole-content
      # replacement, so a file rewritten on disk since is measured again
      # (`Media.decode` keys a local file on its size and mtime). A remote
      # image's size stays: `Media.decode` holds a URL's bytes for the
      # process, so measuring it again could only say the same, and would
      # first lay the rows out without the picture for a frame — a flicker
      # on every re-render of a live preview. A remote image that could not
      # be fetched goes too: `Media.decode` remembers that failure only for
      # `Media.remote_failure_ttl`, so a picture a network blip kept out
      # comes in with a later re-render rather than never; within the TTL
      # the retry is answered from that memory, without the network.
      private def forget_local_image_sizes : Nil
        @image_sizes.reject! { |src, size| size.nil? || !remote_image?(src) }
      end

      # The `Media` children drawing block images this frame, one per
      # picture whose rows meet the viewport (for a caller that wants to
      # know what is on screen, and for specs).
      def block_media : Array(Media::Base)
        @block_images.dup
      end

      # The most rows a picture takes this frame (`#max_image_rows`, else
      # half the viewport's rows, at least one).
      private def image_row_cap : Int32
        @max_image_rows || Math.max(1, (aheight - ivertical) // IMAGE_VIEWPORT_FRACTION)
      end

      # Asks for a relayout of the pictures and a frame.
      private def invalidate_images : Nil
        @images_revision += 1
        update
        update! if window?
      end

      # The rows and columns *img* takes at display row *row*, its left edge
      # at column *offset*, in *avail* columns and at most *cap* rows — its
      # natural size in cells, shrunk by one factor when it exceeds either
      # (see the section comment), never enlarged — or `nil` for an image
      # that cannot be measured (missing, undecodable, or a remote one still
      # being fetched), which reserves no rows.
      private def image_slot(img : TextImageFormat, row : Int32, offset : Int32, avail : Int32, cap : Int32) : ImageSlot?
        return if avail < 1
        src = document.resolve_url(img.name)
        pw, ph = image_pixel_size(src) || return
        cw, ch = image_cell_pixels
        natural_cols = pw.to_f / cw
        natural_rows = ph.to_f / ch
        scale = Math.min(1.0, Math.min(avail / natural_cols, cap / natural_rows))
        cols = (natural_cols * scale).round.to_i.clamp(1, avail)
        rows = (natural_rows * scale).round.to_i.clamp(1, cap)
        ImageSlot.new(row, rows, offset, cols, src)
      end

      # The lines of *img*'s title shown in its picture's place when
      # `media.backend` is `None`: the picture glyph and the title, wrapped
      # to *wrap_width* as the block's text is (`#wrap_block`), one line
      # when not wrapping; none when the image has no title or its title is
      # its alt text, which the caption row already shows.
      private def image_title_lines(img : TextImageFormat, wrap_width : Int32, margin : Int32) : Array(String)
        title = img.title.try(&.strip.gsub(/\s+/, ' ')).presence
        return [] of String if title.nil? || title == img.alt
        text = "#{TextImageFormat.placeholder} #{title}"
        wrap_content? ? wrap_lines(text, wrap_width, margin: margin).lines : [text]
      end

      # *src*'s natural size in pixels, or `nil` when it has none yet: a
      # local file is decoded now (cached), a remote URL is fetched on a
      # fiber and reported through `#invalidate_images` when it arrives.
      private def image_pixel_size(src : String) : Tuple(Int32, Int32)?
        return @image_sizes[src] if @image_sizes.has_key?(src)
        if remote_image?(src)
          fetch_image_size src
          return
        end
        @image_sizes[src] = decode_image_size(src)
      end

      # Decodes *src* (`Media.decode`, the shared cache) for its canvas
      # size; `nil` when it cannot be read or decoded. Nothing escapes: a
      # broken image is a caption row, not an exception on the render fiber.
      private def decode_image_size(src : String) : Tuple(Int32, Int32)?
        png = Media.decode(src) || return
        w, h = png.width, png.height
        w, h = png.canvas_width, png.canvas_height if w <= 0 || h <= 0
        {w, h} if w > 0 && h > 0
      rescue
        nil
      end

      # Starts fetching and decoding the remote *src* on a fiber of its own,
      # once; the size lands on the render fiber (`Window#post`) and the
      # pictures are laid out again. The fetch waits on the network off the
      # render fiber; the decode that follows is a moment's work on it.
      private def fetch_image_size(src : String) : Nil
        return if @image_loading.includes?(src)
        win = window? || return
        @image_loading << src
        spawn(name: "crysterm-image-size") do
          size = decode_image_size(src)
          # On a window closed while the fetch ran, `post` drops the job (the
          # queue is closed with the window); nothing holds this view.
          win.post do
            @image_sizes[src] = size
            @image_loading.delete src
            # An image without a size reserves no rows, as one still
            # loading does: the layout stands.
            invalidate_images if size
          end
        end
      end

      # Keeps one `Media` child per picture whose rows meet the viewport,
      # placed at its document row (see the section comment for how a child
      # of a scrollable widget is scrolled and clipped), reusing a child
      # whose source matches and destroying the rest. Run from `#paint`
      # before the child pass draws them.
      private def sync_block_images : Nil
        if @image_slots.empty? || !@images_enabled
          drop_block_images
          return
        end
        top = @child_base
        bottom = top + visible_content_rows
        spare = @block_images
        kept = [] of Media::Base
        @image_slots.each do |slot|
          next if slot.row + slot.rows <= top || slot.row >= bottom
          whole = slot.row >= top && slot.row + slot.rows <= bottom
          if i = spare.index { |m| m.file == slot.source }
            media = spare.delete_at i
          else
            media = build_block_image(slot.source) || next
          end
          place_block_image media, slot, whole
          kept << media
        end
        spare.each &.destroy
        @block_images = kept
      end

      # A `Media` child for *src*, the backend `Media.resolve` picks for the
      # terminal and the options, which the view follows from now on
      # (`Media.watch_config`). `nil`, with the source marked unusable, when
      # no backend can be built for it (a pinned external helper that is not
      # installed) — the caption row stands alone rather than an exception
      # per frame.
      private def build_block_image(src : String) : Media::Base?
        Media.watch_config
        Media.new(file: src, parent: self, top: 0, left: 0, width: 1, height: 1, fit: Media::Fit::Contain)
      rescue ex
        ::Log.warn(exception: ex) { "Crysterm: no media backend for the image #{src}" }
        @image_sizes[src] = nil
        invalidate_images
        nil
      end

      # Puts *media* on *slot*'s rows and columns: positions relative to the
      # content origin, which `Widget#coords` shifts by the scroll. A
      # terminal-graphics child is shown only while *whole* (see the section
      # comment); a cell-painting one is clipped by the viewport and stays
      # shown.
      private def place_block_image(media : Media::Base, slot : ImageSlot, whole : Bool) : Nil
        media.top = slot.row
        media.left = slot.offset - @child_base_x
        media.width = slot.cols
        media.height = slot.rows
        media.visible = whole || !media.is_a?(Media::Graphics)
      end

      # Destroys every picture child (each backend erases its own image).
      private def drop_block_images : Nil
        return if @block_images.empty?
        @block_images.each &.destroy
        @block_images.clear
      end

      # A run-time change of the media options (`Media.rebuild_resolved`)
      # drops the picture children with the background layer; the next
      # frame builds them for the backend resolved now. The images are laid
      # out again too, as `None` (`Media.disabled?`) puts titles where the
      # pictures were, and back.
      def reset_resolved_media : Nil
        super
        drop_block_images
        invalidate_images if @image_blocks_laid_out
      end
    end
  end
end
