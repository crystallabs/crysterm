module Crysterm
  class Window
    # Per-widget damage / dirty tracking (opt-in via
    # `OptimizationFlag::DamageTracking`).
    #
    # Default render model: clear the whole buffer and re-composite every widget
    # every frame — O(N) even when one widget changed. Damage tracking adds a
    # fast path: on a frame where only a few top-level subtrees changed, clear
    # just their old footprints and re-composite just them, carrying over every
    # other cell.
    #
    # The fast path is *output-equivalent* to the full re-composite — it engages
    # only when it can prove equivalence, else falls back. Phases:
    #
    # - **Phase 1** — opaque, non-overlapping: clear each changed subtree's old
    #   footprint, re-render just it, carry over everything else.
    # - **Phase 2** — overlap & z-order: when a changed subtree's damage touches
    #   another subtree, recomposite the whole connected overlap cluster in
    #   z-order over its cleared region (`#damage_phase2`).
    # - **Phase 3** — opacity / shadow / tint: the cluster recomposite is a
    #   region-local "mini full clear", so per-cell blend effects re-blend over a
    #   freshly rebuilt base (no saturation creep) for free. Requires a widget's
    #   damage rect to include its **shadow** band, which reaches past `@lpos`.
    #
    # Still always full-path: **z-index planes** (separate screen-sized buffer,
    # out of scope), **border docking** (joins glyphs across widgets), and
    # out-of-cell-model writes (`#invalidate_region`, for w3m image overlays).
    # Plus frame-global bailouts: first frame, resize, structural change (child
    # add/remove), stylesheet change.
    #
    # On any precondition failure the frame renders the full way, refreshing the
    # caches below so the next frame can fast-path again.

    # Top-level widgets whose subtree changed since the last paint. Drained every
    # frame.
    @damage_dirty_roots = Set(Widget).new

    # Forces the next frame to be a full re-composite regardless of the dirty
    # set. Set on the first frame, on structural changes, and whenever the fast
    # path cannot prove itself safe.
    @damage_force_full = true

    # Set during a render when something the selective path can't reproduce
    # happened — a write outside the cell model. Reset each frame; forces a
    # fallback during a fast-path attempt. Plane usage is tracked separately via
    # `@layer_widgets`.
    @frame_used_effects = false

    # Whether the most recently completed *full* frame can be safely carried over
    # cell-by-cell: no planes, no docking, nothing written outside the cell model.
    # Per-cell blend effects (opacity/shadow/tint) do NOT disqualify a frame — the
    # cluster recomposite reproduces them (Phase 3).
    @damage_safe = false

    # Window dimensions at the last full frame; a change means a resize, which
    # rebuilds the buffer and invalidates every carried-over cell.
    @damage_last_awidth = -1
    @damage_last_aheight = -1

    # Counters (tests/benchmarks): frames that took the selective fast path vs.
    # fell back to a full re-composite, since the screen was created.
    getter damage_fast_frames = 0
    getter damage_full_frames = 0

    # Reused per-frame scratch (cleared, not reallocated): this frame's
    # dirty-root snapshot and damaged-rect list.
    @damage_snapshot = [] of Widget
    @damage_rects = [] of Tuple(Int32, Int32, Int32, Int32)

    # Reused scratch buffer: the rectangles (member footprints + glue) defining
    # the cluster's extent, which the selective recomposite clears.
    @damage_frontier = [] of Tuple(Int32, Int32, Int32, Int32)

    # --- Phase 4 — z-index planes -------------------------------------------
    #
    # Whether the last *full* frame used **exactly one** plane (single z-index),
    # every layer widget a top-level child, no out-of-cell-model effects or
    # docking. Only then may the next frame take the selective *plane* path;
    # multi-plane / nested-layer frames stay full.
    @damage_plane_safe = false

    # The single plane's z-index, recorded on the last full frame (valid only
    # when `@damage_plane_safe`).
    @damage_plane_z = 0

    # The layer roots (top-level children with a `z_index`) that fed the single
    # plane on the last full frame. The selective plane frame requires the same
    # set; a z-index added/removed/changed falls back to full. Reused across frames.
    @damage_layer_roots = [] of Widget

    # Reused scratch for recomputing this frame's layer roots, to compare against
    # `@damage_layer_roots` without allocating.
    @damage_cur_layers = [] of Widget

    # --- Cost-based fallback (keeps the selective path "never worse than full") -
    #
    # The selective path only wins when the changed/overlapping region is a
    # small fraction of the screen; past that it does the full-recomposite work
    # *plus* bookkeeping. These let the engine decide, in cells, whether to even
    # attempt it — no tuned ratios.

    # Σ of every top-level child subtree's area (cells), refreshed on each full
    # frame alongside `damage_bounds`. With the screen area, the full path's cost,
    # against which a selective attempt is measured.
    @damage_all_area = 0_i64

    # Stamp for O(1) "is this widget in the current cluster?" membership during the
    # overlap grow, via `Widget#damage_seen`: a widget is a member iff its stamp
    # equals this one, so there is no per-frame allocation or reset. Bumped per
    # grow; `Int64` so it never wraps for the life of the process.
    @damage_stamp = 0_i64

    # --- Overlap-grow via cell grid + union-find (replaces the O(N^3) fixpoint) -
    #
    # The connected cluster of overlapping top-level subtrees is found by
    # rasterizing each base child's rectangle into a screen-sized cell grid and
    # union-ing children that land on the same cell — transitive overlap falls
    # out of the union-find in ~O(Σ areas) instead of a fixpoint scan. The grid
    # is stamp-addressed (a cell belongs to this grow iff its stamp matches), so
    # there's no per-grow O(W*H) reset; it's only (re)sized on a resize. Each
    # cell packs `(stamp << 32) | owner-base-index` into one `Int64` so the hot
    # rasterize loop touches a single array (one cache line) per cell.
    @damage_grid = [] of Int64
    @damage_grid_w = 0
    # Union-find parent array, indexed by base-child position (`Widget#damage_idx`).
    @damage_uf = [] of Int32
    # Reused list of this frame's base (non-z) top-level children, in z order.
    @damage_base = [] of Widget
    # Each dirty root's OLD footprint (parallel to the dirty snapshot), captured
    # before re-render so the cluster can pull in whatever it vacated.
    @damage_dirty_old = [] of Tuple(Int32, Int32, Int32, Int32)?
    # Per-base-index marker: a union-find root carries the seed stamp iff its
    # component contains a changed subtree. Reused; sized to the base-child count.
    @damage_seedmark = [] of Int64
    # Reused list of "glue" rectangles handed to the cluster builder: cells that
    # must be cleared and that pull whatever base child sits under them into the
    # cluster (a changed root's vacated footprint; for Phase 4, the plane region).
    @damage_glue = [] of Tuple(Int32, Int32, Int32, Int32)

    # Self-measured payoff: exponential moving averages (µs) of full- and
    # selective-composite cost, plus a sticky "selective isn't paying here" flag.
    # The cell-cost model above can't see per-cell blend cost or detection
    # overhead, so this backstop measures real wall time, disables the selective
    # attempt when it stops winning, re-probes periodically, and re-arms on any
    # full frame forced by a structural/stylesheet change.
    @damage_full_ema = -1.0
    @damage_sel_ema = -1.0
    @damage_prefer_full = false
    @damage_reprobe = 0

    # Half-open rectangle area in cells (0 for nil/empty).
    private def damage_rect_area(r : Tuple(Int32, Int32, Int32, Int32)?) : Int64
      return 0_i64 unless r
      w = r[1] - r[0]
      h = r[3] - r[2]
      return 0_i64 if w <= 0 || h <= 0
      w.to_i64 * h
    end

    # Cost of the full (non-selective) repaint path: every screen cell plus the
    # accumulated all-widget area. The selective path only wins below this.
    private def damage_full_cost : Int64
      awidth.to_i64 * aheight + @damage_all_area
    end

    # Whether this frame is out of scope for the selective damage path: a
    # per-frame blend effect ran, or a nested layer/plane is present. Either
    # forces a fall back to the full path.
    private def damage_out_of_scope? : Bool
      @frame_used_effects || !@layer_widgets.empty?
    end

    # Registers *w* (via its top-level ancestor) as needing a repaint next frame.
    #
    # Only the selective damage path consumes the dirty-roots set, so with tracking
    # off (the default) this must bail immediately: every state-changing setter
    # calls it, and the parent-chain walk + `Set` insert would be thousands of
    # pointless ops per frame in a per-cell animation.
    def damage_mark_dirty(w : Widget) : Nil
      return unless @optimization.damage_tracking?
      @damage_dirty_roots << w.top_level_ancestor
    end

    # Forces the next frame to be a full re-composite.
    def damage_force_full : Nil
      @damage_force_full = true
    end

    # Structural-change hook: a child was added to / removed from the screen itself.
    # Rings the doorbell too so an idle UI repaints the vacated cells; a top-level
    # `Window#remove`/append has no other frame trigger. `#request_frame` is
    # in_render-safe.
    protected def _damage_invalidate_structure : Nil
      damage_force_full
      request_frame
    end

    # Records that something the selective path can't reproduce happened this
    # frame — a write outside the cell model — forcing a full-path fallback.
    # Per-cell blend effects (opacity/shadow/tint) do NOT call this: the cluster
    # recomposite handles them (Phase 3), and planes go through `@layer_widgets`.
    def note_effect : Nil
      @frame_used_effects = true
    end

    # How often (frames) to re-probe the selective path while latched off. Not a
    # perf knob — controls how fast the engine re-adapts after a scene shift that
    # doesn't already force a full frame (structural/stylesheet/resize re-arm it
    # immediately). Generous so a degenerate scene rarely pays the probe.
    DAMAGE_REPROBE_FRAMES = 120

    # Compositing entry point under damage tracking: decides whether to attempt the
    # selective path this frame, runs it (or the full path), and feeds the
    # self-measured backstop. A degenerate scene settles to full-recomposite cost
    # while a scene the fast path helps keeps using it.
    private def damage_composite : Nil
      # A frame that MUST be full (first frame, structural/stylesheet/resize) is
      # uninformative about whether selective pays — run it, and re-arm so the
      # next frame re-evaluates from scratch.
      if @damage_force_full
        damage_full_composite_timed
        @damage_prefer_full = false
        @damage_reprobe = 0
        return
      end

      # While latched off, skip the attempt entirely (this is the win for a
      # persistently-degenerate scene) until a periodic re-probe is due.
      attempt = !@damage_prefer_full
      unless attempt
        @damage_reprobe -= 1
        attempt = @damage_reprobe <= 0
      end

      unless attempt
        damage_full_composite_timed
        return
      end

      t0 = Time.instant
      if damage_try_composite
        sel = (Time.instant - t0).total_microseconds
        @damage_sel_ema = damage_ema @damage_sel_ema, sel
        # Keep using selective unless it has measured slower than the full path.
        @damage_prefer_full = @damage_full_ema >= 0 && @damage_sel_ema > @damage_full_ema
        @damage_reprobe = DAMAGE_REPROBE_FRAMES if @damage_prefer_full
      else
        # Selective couldn't win this frame (cost parity / cluster grew to the
        # whole screen) and fell back. Measure the full path and latch selective
        # off, re-probing later.
        damage_full_composite_timed
        @damage_prefer_full = true
        @damage_reprobe = DAMAGE_REPROBE_FRAMES
      end
    end

    # Exponential moving average (first sample seeds it). 0.2 weight = a handful
    # of frames of memory, enough to smooth jitter without lagging scene changes.
    private def damage_ema(cur : Float64, sample : Float64) : Float64
      cur < 0 ? sample : cur * 0.8 + sample * 0.2
    end

    # Runs the full re-composite and folds its measured wall-clock cost into the
    # full-path EMA.
    private def damage_full_composite_timed : Nil
      t = Time.instant
      damage_full_composite
      @damage_full_ema = damage_ema @damage_full_ema, (Time.instant - t).total_microseconds
    end

    # Full re-composite. Clears the whole buffer and re-renders every top-level
    # child (deferring z-indexed ones to planes), then composites planes and docks.
    # Also refreshes the damage caches when damage tracking is enabled, so a
    # subsequent frame can take the fast path.
    private def damage_full_composite : Nil
      # Consume the dirty set BEFORE rendering: this frame satisfies every pending
      # mark, while marks raised DURING the render (a widget calling `set_content`
      # from its own `#render`, a CSS keyframe step) must survive to drive the next.
      @damage_dirty_roots.clear if @optimization.damage_tracking?

      clear_region 0, awidth, 0, aheight

      @layer_widgets.clear
      @render_index_cursor = 0
      @children.each do |el|
        el.render_index = @render_index_cursor
        @render_index_cursor += 1
        # Base layer: paint straight into `@lines`. A child declaring a
        # `z_index` is deferred to its own plane (composited below).
        if el.style.z_index
          defer_layer el
        else
          el.render
        end
      end
      @render_index_cursor = -1

      composite_planes

      _dock if @dock_borders

      if @optimization.damage_tracking?
        # Refresh per-subtree bounds and the cost-model caches, and decide whether
        # the next frame may fast-path.
        @damage_all_area = 0_i64
        @children.each do |el|
          b = damage_subtree_bounds el
          el.damage_bounds = b
          @damage_all_area += damage_rect_area(b)
        end
        no_planes = @layer_widgets.empty?
        @damage_safe = !@frame_used_effects && no_planes && !@dock_borders

        # Phase 4: a single-plane frame (one z-index, all layer widgets top-level,
        # no out-of-model effects, no docking) can be carried over and selectively
        # re-folded next frame. Record the plane's z and its layer roots so the
        # next frame can validate that the structure is unchanged.
        @damage_plane_safe = false
        unless no_planes || @frame_used_effects || @dock_borders
          if @sorted_zs.size == 1 && @layer_widgets.all? { |w| w.parent.nil? }
            @damage_plane_safe = true
            @damage_plane_z = @sorted_zs.first[0]
            @damage_layer_roots.clear
            @children.each { |el| @damage_layer_roots << el if el.style.z_index }
          end
        end

        @damage_force_full = false
        @damage_last_awidth = awidth
        @damage_last_aheight = aheight
        @damage_full_frames += 1
      else
        # Tracking is off: the caches above (damage_bounds, `@damage_safe`, dims)
        # are frozen at their last tracked-frame values while the scene keeps
        # changing under full composites. Poison the fast path so the first
        # frame after re-enabling runs full and refreshes them — otherwise the
        # selective path would clear stale footprints, leaving ghosts.
        @damage_force_full = true
      end
    end

    # Re-renders a changed root in place: clears its *old* footprint (vacated cells
    # revert to bare base), repaints it, then recomputes and stores its new bounds.
    # Returns `{old, new}`; pushing `old` into a vacated-footprint accumulator is
    # left to the caller.
    private def damage_reclear_root(root : Widget) : {Tuple(Int32, Int32, Int32, Int32)?, Tuple(Int32, Int32, Int32, Int32)?}
      old = root.damage_bounds
      clear_region old[0], old[1], old[2], old[3] if old
      root.render
      nb = damage_subtree_bounds root
      root.damage_bounds = nb
      {old, nb}
    end

    # Attempts the selective (damage-tracking) composite. Returns `true` if it
    # painted the frame, or `false` if a precondition failed and the caller must
    # run `damage_full_composite` instead. Any partial writes it made are
    # overwritten by the full path's whole-buffer clear, so a `false` return is
    # always safe.
    private def damage_try_composite : Bool
      # Cheap, frame-global preconditions.
      return false if @damage_force_full
      return false if @damage_last_awidth < 0 # no prior full frame yet
      # The last full frame must be carry-over-safe either as a plain frame or as a
      # single-plane frame (Phase 4). The two are mutually exclusive.
      return false unless @damage_safe || @damage_plane_safe
      return false if @dock_borders # docking joins across widgets
      return false if awidth != @damage_last_awidth || aheight != @damage_last_aheight

      # Snapshot the dirty roots and clear the live set BEFORE re-rendering, so
      # marks raised during the re-render carry to the next frame. A `false` return
      # falls back to the full path, correct regardless of the cleared set.
      dirty = @damage_snapshot
      dirty.clear
      @damage_dirty_roots.each { |r| dirty << r }
      @damage_dirty_roots.clear

      # Every dirty root must still be a current top-level child (no structural
      # change snuck past the structural hook). A z-indexed (layer) root is only
      # acceptable on the Phase 4 plane path; on the plain path it forces a full
      # frame (which sets the plane up).
      dirty.each do |r|
        return false unless r.parent.nil? && @children_set.includes?(r)
        return false if r.style.z_index && !@damage_plane_safe
      end

      # Nothing to do: no changed subtree. The buffer already matches last frame,
      # so `draw` emits nothing.
      if dirty.empty?
        @damage_fast_frames += 1
        return true
      end

      # Phase 4: the last frame was a single-plane frame, so route to the plane
      # composite (it rebuilds the base under the plane and re-folds the plane).
      if @damage_plane_safe
        return damage_plane_composite dirty
      end

      # Up-front cost parity, O(dirty) from cached bounds. The selective path must
      # clear each changed subtree's *old* footprint AND repaint its *new* one —
      # >= `2 * Σ changed-area` cells — before any overlap pulls in more, so if
      # that already meets the full cost it can't win: fall back before any render
      # work. Catches the "(almost) everything changed" degeneracy, where the
      # cluster would otherwise grow to the whole screen at super-linear cost.
      full_cost = damage_full_cost
      dirty_area = 0_i64
      dirty.each { |r| dirty_area += damage_rect_area(r.damage_bounds) }
      return false if 2_i64 * dirty_area >= full_cost

      @layer_widgets.clear

      # Clear each changed subtree's old footprint, re-render it, and collect the
      # union (old ∪ new) rectangle that was damaged.
      damaged = @damage_rects
      damaged.clear
      olds = @damage_dirty_old
      olds.clear
      dirty.each do |root|
        old, nb = damage_reclear_root root
        olds << old
        if rect = damage_union(old, nb)
          damaged << rect
        end
      end

      # A z-indexed descendant got deferred to a plane, or something wrote outside
      # the cell model. Either is out of scope for the selective path. (Per-cell
      # blend effects do NOT trip this — the cluster recomposite reproduces them.)
      return false if damage_out_of_scope?

      # Does any changed subtree overlap another top-level subtree — changed or
      # unchanged? If not, the changed subtrees are self-contained and the
      # per-root renders above are final (Phase 1).
      unless damage_needs_cluster? dirty, damaged
        @damage_fast_frames += 1
        return true
      end

      # Phase 2/3: a changed subtree overlaps another — recomposite the
      # overlapping widgets together in z-order (blend effects among them
      # re-blend over a freshly rebuilt base). A false result means a plane /
      # out-of-model write surfaced and the caller must fall back to full.
      return false unless damage_phase2 dirty, damaged

      @damage_fast_frames += 1
      true
    end

    # Phase 2 — overlap / z-order. Recomposites the connected cluster of
    # top-level children (by bounding-box overlap) that contains the changed
    # subtrees: clears the cluster's whole region and repaints every member in
    # `@children` (z) order. Members outside the cluster provably don't overlap
    # it, so leaving them untouched is correct, and clearing the cluster region
    # cannot disturb their cells.
    #
    # `dirty` are the changed roots (already rendered once this frame, with
    # up-to-date `damage_bounds`); `damaged` holds their old∪new rectangles. A
    # `false` return means a plane or out-of-model write surfaced during the
    # repaint — fall back to full.
    private def damage_phase2(dirty : Array(Widget), damaged : Array(Tuple(Int32, Int32, Int32, Int32))) : Bool
      frontier = @damage_frontier
      frontier.clear

      # Glue = each changed root's old footprint, so a widget the move uncovered
      # is pulled into the cluster and its vacated cells repainted.
      glue = @damage_glue
      glue.clear
      @damage_dirty_old.each { |o| glue << o if o }

      cluster_area = damage_build_cluster dirty, glue, frontier

      # Post-grow cost parity: clearing and repainting the cluster costs at least
      # ~2 * its area; if that already meets the full path's cost, fall back —
      # catches an overlap cluster that grew to (nearly) the whole screen (e.g.
      # thousands of stacked single-cell widgets).
      return false if 2_i64 * cluster_area >= damage_full_cost

      # Clear each member's footprint and the changed roots' vacated cells, then
      # repaint every member in `@children` (z) order.
      damage_repaint_cluster frontier

      !damage_out_of_scope?
    end

    # Clears the cluster's cells (*frontier* = member footprints + glue) and
    # repaints every cluster member — a base (non-z) child marked with the
    # current `@damage_stamp` — in `@children` (z) order, refreshing its bounds.
    # Shared by the Phase 2 overlap recomposite and the Phase 4 plane base rebuild.
    private def damage_repaint_cluster(frontier : Array(Tuple(Int32, Int32, Int32, Int32))) : Nil
      frontier.each { |r| clear_region r[0], r[1], r[2], r[3] }
      stamp = @damage_stamp
      @children.each do |el|
        next if el.style.z_index
        next unless el.damage_seen == stamp
        el.render
        el.damage_bounds = damage_subtree_bounds el
      end
    end

    # Builds the connected cluster of base (non-z) top-level children to
    # recomposite, shared by Phase 2 and the Phase 4 plane base rebuild. Every base
    # child's footprint is rasterized into the stamp-addressed cell grid and
    # overlapping children are union-found (half-open rect intersection ⟺ a shared
    # integer cell), so transitive overlap falls out in ~O(Σ areas) instead of an
    # O(N^3) fixpoint. A component joins the cluster if it contains a `seeds` root
    # (a changed subtree) OR any base child sitting under a `glue` rectangle (a
    # vacated footprint, or the plane's covered region). Marks each member with
    # `damage_seen == @damage_stamp`, appends every member's footprint and all the
    # glue rects to `frontier` (the cells the caller clears), and returns the
    # cluster's total area (for the cost-parity decision).
    private def damage_build_cluster(
      seeds : Array(Widget),
      glue : Array(Tuple(Int32, Int32, Int32, Int32)),
      frontier : Array(Tuple(Int32, Int32, Int32, Int32)),
    ) : Int64
      base = @damage_base
      base.clear
      @children.each do |el|
        next if el.style.z_index
        el.damage_idx = base.size
        base << el
      end
      m = base.size

      # The Int64 membership stamp (never wraps) drives `damage_seen`/`seed`. The
      # grid packs its cell-stamp into a 31-bit field (so `<< 32` stays a positive
      # Int64), taken from the low bits of the stamp; that field wraps every 2^31
      # grows, at which point the grid is cleared once so the monotonic `v >= s64`
      # test still distinguishes this grow's cells from stale ones.
      @damage_stamp += 1
      stamp = @damage_stamp
      g = stamp & 0x7FFFFFFF
      grid_wrapped = false
      if g == 0
        @damage_stamp += 1
        stamp = @damage_stamp
        g = 1_i64
        grid_wrapped = true
      end
      s64 = g << 32

      # (Re)size the cell grid on a dimension change, or clear it on a stamp wrap;
      # otherwise it is stamp-addressed and needs no per-frame clear.
      w = awidth
      h = aheight
      ncells = w * h
      if @damage_grid_w != w || @damage_grid.size != ncells
        @damage_grid = Array(Int64).new(ncells, 0_i64)
        @damage_grid_w = w
      elsif grid_wrapped
        @damage_grid.fill(0_i64)
      end
      grid = @damage_grid

      uf = @damage_uf
      uf.clear
      m.times { |i| uf << i }

      # Rasterize every base child; union children that share a cell. A cell holds
      # `(stamp << 32) | owner`; a high-half mismatch means it's from an older grow
      # (no clear needed) and this child claims it.
      base.each do |el|
        idx = el.damage_idx
        damage_rasterize(el.damage_bounds, w, h) do |cell|
          v = grid.unsafe_fetch(cell)
          if v >= s64
            damage_uf_union uf, idx, (v & 0xFFFFFFFF).to_i32
          else
            grid.unsafe_put(cell, s64 | idx)
          end
        end
      end

      # Seed the components of the changed roots (the seed marker is also
      # stamped, so the array only needs growing — never clearing — across frames).
      seed = @damage_seedmark
      (seed.size...m).each { seed << 0_i64 }
      seeds.each do |r|
        next if r.style.z_index
        seed.unsafe_put(damage_uf_find(uf, r.damage_idx), stamp)
      end

      # ...and of whatever base child sits under each glue rectangle.
      glue.each do |gr|
        damage_rasterize(gr, w, h) do |cell|
          v = grid.unsafe_fetch(cell)
          seed.unsafe_put(damage_uf_find(uf, (v & 0xFFFFFFFF).to_i32), stamp) if v >= s64
        end
      end

      # Collect the cluster's members in z order, mark them, and total their area.
      cluster_area = 0_i64
      base.each do |el|
        if seed.unsafe_fetch(damage_uf_find(uf, el.damage_idx)) == stamp
          el.damage_seen = stamp
          if b = el.damage_bounds
            frontier << b
            cluster_area += damage_rect_area(b)
          end
        end
      end
      glue.each { |gr| frontier << gr }
      cluster_area
    end

    # Iterates the integer cell indices (`y * w + x`) a half-open rectangle covers
    # within the `w`x`h` screen, clamped to bounds (a shadow band can reach past
    # the edge).
    private def damage_rasterize(r : Tuple(Int32, Int32, Int32, Int32)?, w : Int32, h : Int32, &)
      return unless r
      xi = r[0] < 0 ? 0 : r[0]
      yi = r[2] < 0 ? 0 : r[2]
      xl = r[1] > w ? w : r[1]
      yl = r[3] > h ? h : r[3]
      y = yi
      while y < yl
        rowbase = y * w
        x = xi
        while x < xl
          yield rowbase + x
          x += 1
        end
        y += 1
      end
    end

    # Union-find with path halving over the base-index parent array `uf`.
    private def damage_uf_find(uf : Array(Int32), i : Int32) : Int32
      while (p = uf.unsafe_fetch(i)) != i
        gp = uf.unsafe_fetch(p)
        uf.unsafe_put(i, gp)
        i = gp
      end
      i
    end

    private def damage_uf_union(uf : Array(Int32), a : Int32, b : Int32) : Nil
      ra = damage_uf_find uf, a
      rb = damage_uf_find uf, b
      uf.unsafe_put(ra, rb) if ra != rb
    end

    # Phase 4 — single z-index plane. Reached only when the last full frame was a
    # single-plane frame (`@damage_plane_safe`). A z-indexed widget is composited
    # through a separate screen-sized `Plane` folded over the base after the base
    # is painted; base cells under the plane already carry last frame's fold, so
    # re-folding over them would saturate. This method rebuilds the base
    # **pre-plane** in the plane's covered region (and any connected base
    # sub-cluster), then re-folds the plane over just that region — a
    # region-local version of what the full path does for the whole screen.
    #
    # Scope: one plane (single z-index), all layer widgets top-level. Anything
    # else (multi-plane, nested layers, an out-of-model write) returns `false`
    # and the caller falls back to the full path.
    private def damage_plane_composite(dirty : Array(Widget)) : Bool
      z = @damage_plane_z
      pl = @planes[z]?
      return false unless pl

      # Recompute this frame's layer roots and require the structure to match
      # what the last full frame recorded: same widgets, all still at the single
      # z. A z-index added/removed/changed (or a second plane appearing) means
      # the layout changed — fall back to full.
      cur = @damage_cur_layers
      cur.clear
      @children.each do |el|
        if zi = el.style.z_index
          return false unless zi == z
          cur << el
        end
      end
      return false if cur.empty?
      return false unless cur.size == @damage_layer_roots.size
      cur.each { |el| return false unless @damage_layer_roots.includes? el }

      # The full path (`composite_planes`) folds same-z roots with differing
      # opacity as separate per-opacity groups; this fast path folds them as
      # ONE plane with a single opacity, so it only holds when every root
      # shares the same opacity — otherwise fall back to the full path.
      opacity0 = cur.first.style.opacity? || 1.0
      cur.each { |el| return false unless (el.style.opacity? || 1.0) == opacity0 }

      # The plane's covered rectangle as of last frame (union of its layer roots'
      # recorded footprints).
      plane_old = nil
      cur.each { |el| plane_old = damage_union(plane_old, el.damage_bounds) }

      # Re-render the plane into its own buffer if any of its widgets changed —
      # mirroring `composite_planes` for this single z (clear, opacity from the
      # root's opacity, render each member opaquely into the plane). If nothing
      # changed, the plane buffer still holds last frame's content and is folded
      # as-is below.
      @layer_widgets.clear
      layer_changed = dirty.any? &.style.z_index
      if layer_changed
        # Opacity is a fold-time property (read by `composite_onto`), so it's set
        # just before the fold below, not here.
        pl.clear
        @compositing_layers = true
        begin
          render_members_into_plane pl, cur
        ensure
          @compositing_layers = false
        end
        # A nested z-index inside the layer got deferred again (a second plane) —
        # out of scope, fall back.
        return false unless @layer_widgets.empty?
        cur.each { |el| el.damage_bounds = damage_subtree_bounds el }
      end

      # The plane's covered rectangle as of this frame (after any re-render).
      plane_new = nil
      cur.each { |el| plane_new = damage_union(plane_new, el.damage_bounds) }

      # Re-render the base-layer (non-z) dirty roots to learn their new footprints
      # (clearing each one's old footprint first), capturing the old footprints as
      # cluster glue — a moved base widget's vacated cells must be rebuilt. These
      # roots are repainted again as part of the cluster below.
      olds = @damage_dirty_old
      olds.clear
      dirty.each do |root|
        next if root.style.z_index
        old, _ = damage_reclear_root root
        olds << old
      end
      # A base dirty root deferred a nested layer, or wrote outside the cell model.
      return false if damage_out_of_scope?

      # Build the pre-plane rebuild cluster (same grid/union-find as Phase 2). The
      # glue rects pull in whatever base sits under a changed root's vacated
      # footprint OR under the plane's covered region (old∪new): that base must
      # be rebuilt and the plane re-folded over it, and a vacated part (where the
      # plane moved away) must revert to bare base.
      frontier = @damage_frontier
      frontier.clear
      glue = @damage_glue
      glue.clear
      olds.each { |o| glue << o if o }
      glue << plane_old if plane_old
      glue << plane_new if plane_new && plane_new != plane_old

      cluster_area = damage_build_cluster dirty, glue, frontier

      # Cost parity: if rebuilding the cluster and re-folding the plane already
      # costs ~a full frame, fall back — keeps the plane path "never worse than
      # full" even for a plane over a large, fully-changing base.
      plane_area = plane_new ? damage_rect_area(plane_new) : 0_i64
      return false if 2_i64 * cluster_area + plane_area >= damage_full_cost

      # Clear the cluster's cells (member footprints + glue) and repaint members
      # in `@children` (z) order — a region-local pre-plane base rebuild.
      damage_repaint_cluster frontier
      return false if damage_out_of_scope?

      # Re-fold the plane over its (now freshly rebuilt, pre-plane) covered
      # region. Opacity is recomputed from the root's current opacity each frame.
      if plane_new
        pl.opacity = cur.first.style.opacity? || 1.0
        pl.composite_onto @lines, plane_new[0], plane_new[1], plane_new[2], plane_new[3]
      end

      @damage_fast_frames += 1
      true
    end

    # Union of *root*'s and all its descendants' `@lpos` rectangles, as a
    # half-open `{xi, xl, yi, yl}`, or `nil` when nothing in the subtree rendered
    # to a non-empty rectangle.
    #
    # Written as plain recursion over value tuples (rather than
    # `self_and_each_descendant`, which captures a heap `Proc` per call) so it
    # allocates nothing — runs once per changed root on the per-frame fast path.
    private def damage_subtree_bounds(root : Widget) : Tuple(Int32, Int32, Int32, Int32)?
      acc = damage_widget_rect root
      root.children.each do |c|
        acc = damage_union acc, damage_subtree_bounds(c)
      end
      acc
    end

    # This widget's own painted rectangle: its `@lpos`, expanded by its `shadow`
    # band (Phase 3) when it has one. A shadow blends a strip of cells *outside*
    # `@lpos` (`xi - left` … `xl + right`, `yi - top` … `yl + bottom`), so it must
    # be part of the damage rect — both to clear the old shadow and to pull the
    # widgets it falls on into the recomposite cluster. `nil` if the widget didn't
    # render to a non-empty rectangle.
    private def damage_widget_rect(w : Widget) : Tuple(Int32, Int32, Int32, Int32)?
      lp = w.lpos
      return nil unless lp
      return nil if lp.xl <= lp.xi || lp.yl <= lp.yi
      xi = lp.xi
      xl = lp.xl
      yi = lp.yi
      yl = lp.yl
      if (s = w.style.shadow) && s.any?
        xi -= s.left
        xl += s.right
        yi -= s.top
        yl += s.bottom
      end
      {xi, xl, yi, yl}
    end

    # Does any changed subtree's damage rectangle overlap another top-level
    # subtree — unchanged (`damage_bounds`) or another changed one (`damaged`)?
    # When false, the changed subtrees are mutually disjoint and isolated, so the
    # per-root renders are final and no cluster recomposite is needed.
    private def damage_needs_cluster?(dirty : Array(Widget), damaged : Array(Tuple(Int32, Int32, Int32, Int32))) : Bool
      # Changed vs unchanged.
      @children.each do |el|
        next if dirty.includes? el
        cb = el.damage_bounds
        next unless cb
        return true if damaged.any? { |d| damage_rects_overlap?(d, cb) }
      end
      # Changed vs changed.
      i = 0
      while i < damaged.size
        j = i + 1
        while j < damaged.size
          return true if damage_rects_overlap?(damaged.unsafe_fetch(i), damaged.unsafe_fetch(j))
          j += 1
        end
        i += 1
      end
      false
    end

    # Half-open rectangle overlap test (`{xi, xl, yi, yl}`).
    private def damage_rects_overlap?(a : Tuple(Int32, Int32, Int32, Int32), b : Tuple(Int32, Int32, Int32, Int32)) : Bool
      a[0] < b[1] && b[0] < a[1] && a[2] < b[3] && b[2] < a[3]
    end

    # Bounding union of two optional rectangles.
    private def damage_union(a : Tuple(Int32, Int32, Int32, Int32)?, b : Tuple(Int32, Int32, Int32, Int32)?) : Tuple(Int32, Int32, Int32, Int32)?
      return b unless a
      return a unless b
      {
        a[0] < b[0] ? a[0] : b[0],
        a[1] > b[1] ? a[1] : b[1],
        a[2] < b[2] ? a[2] : b[2],
        a[3] > b[3] ? a[3] : b[3],
      }
    end
  end
end
