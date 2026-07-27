module Crysterm
  # Central home for Crysterm's caches.
  #
  # Crysterm memoizes many computed results (loaded fonts, converted colors,
  # decoded images, per-widget layout/attr memos, …). This module holds the shared
  # machinery: a bounded, self-evicting cache type (`Cache::Bounded`), a registry
  # making every *process-wide* cache introspectable and clearable from one place,
  # and the catalog of size caps below.
  #
  # ## What lives here vs. what stays put
  #
  # * **Process-wide caches** (fonts, color conversions, image decodes) are
  #   *defined* here as module-level instances and register themselves, so
  #   `Cache.stats` / `Cache.clear_all` see them.
  # * **Per-instance caches** (a memo tied to one widget/painter/document) stay
  #   with their instance — they must live, invalidate and die with it. They may
  #   still use `Cache::Bounded` for a size cap (reading a `*_CAPACITY` constant
  #   here), but must **not** register globally: tracking thousands of short-lived
  #   instance caches in a process-global list would leak them.
  #
  # ## Catalog of caps
  #
  # Every cache's entry cap is a constant here, so this file is the one place to
  # see and tune them. `0` (or any non-positive value) means "unbounded".
  module Cache
    # -- Capacity catalog ------------------------------------------------------
    #
    # Process-wide caches:

    # `BitmapFont.load` — loaded bitmap faces, keyed by path+weight. A handful at most.
    FONT_CAPACITY = 64

    # `Colors.convert_cached` — color spec string → packed `Int32`. The set of
    # distinct color strings an app uses is small and stable.
    COLOR_CAPACITY = 1024

    # `Widget::Media.decode` — decoded images/videos keyed by path+size+mtime
    # (a `nil` value is a cached *failure*). Entries can be large, so keep a
    # modest window and evict least-recently-used ones under pressure.
    IMAGE_DECODE_CAPACITY = 64

    # Per-instance caches (defined with their owning class; their cap lives here
    # so the catalog is complete, but they do not register globally):

    # `Widget::…::TextOverlay#overlay_attr` (graph painter) — `{color, bg}` →
    # packed cell attr. A graph uses a small, fixed set of series colors.
    GRAPH_ATTR_CAPACITY = 256

    # `Widget::Media::Ansi#quantize` — source RGB → nearest-palette RGB. A photo
    # can present many distinct inputs, so cap the memo to bound memory across a
    # long-lived widget's re-renders.
    MEDIA_QUANT_CAPACITY = 8192

    # `Style::CSS::Stylesheet#compiled_selector` — selector string → compiled
    # selector (a `nil` entry marks an unparseable one). Naturally bounded by a
    # stylesheet's rule count; the cap is a generous ceiling.
    SELECTOR_CAPACITY = 2048

    # `Widget::Menu#item_on_surface` — source `Style` → surface-filled copy,
    # keyed by object identity. Bounded by the menu's item count and dropped on
    # every cascade/`bg` change; the cap is a generous ceiling.
    MENU_SURFACE_CAPACITY = 512

    # `Widget::ListTable` CSS-row derived styles (`css_without_border` /
    # `css_alt_overlay`) — source `Style` → derived `Style`, keyed by identity.
    # Bounded by the table's row count and dropped when the cascade replaces the
    # widget's styles; the cap is a generous ceiling.
    LISTTABLE_ROW_CAPACITY = 1024

    # -- Registry --------------------------------------------------------------

    # The introspectable interface a registered cache exposes: it can be
    # enumerated, sized and cleared through `Cache`.
    module Registered
      abstract def name : String
      abstract def size : Int32
      abstract def capacity : Int32
      abstract def clear : Nil
    end

    @@registry = [] of Registered

    # Registers *cache* so it shows up in `stats` and is emptied by `clear_all`.
    # Called automatically by `Bounded.new(register: true)`.
    def self.register(cache : Registered) : Nil
      @@registry << cache
    end

    # All registered (process-wide) caches.
    def self.registry : Array(Registered)
      @@registry
    end

    # Empties every registered cache. Useful for reclaiming memory or resetting
    # state between tests.
    def self.clear_all : Nil
      @@registry.each &.clear
    end

    # A `{name, size, capacity}` snapshot of every registered cache.
    def self.stats : Array(NamedTuple(name: String, size: Int32, capacity: Int32))
      @@registry.map do |c|
        {name: c.name, size: c.size, capacity: c.capacity}
      end
    end

    # A size-bounded memoization cache. The generic implementation
    # (FIFO/LRU eviction, memoizing `fetch` that caches `nil`, `by_identity`
    # keying) lives in the crystallabs-helpers shard as
    # `Crystallabs::Helpers::BoundedCache`; this subclass adds only what is
    # crysterm-specific — the `Cache.stats`/`clear_all` registry integration.
    #
    # Not thread-safe: Crysterm's caches are touched from the single event loop.
    class Bounded(K, V) < Crystallabs::Helpers::BoundedCache(K, V)
      include Registered

      # A human-readable name (shown by `Cache.stats`); `"(anonymous)"` when
      # constructed without one.
      getter name : String

      # Creates a cache holding at most *capacity* entries.
      #
      # *name* labels it for `Cache.stats`. *register* adds it to the global
      # `Cache` registry — do this for process-wide caches, never for
      # per-instance ones (they would accumulate and leak). *lru* switches
      # eviction from FIFO to least-recently-used. *by_identity* keys the cache
      # on object identity (`same?`) instead of value equality — for caches
      # memoizing per-object results (e.g. a `Style` instance → its rendered
      # output), mirroring `Hash#compare_by_identity`.
      def initialize(capacity : Int32, name : String? = nil, *, register : Bool = false, lru : Bool = false, by_identity : Bool = false)
        super(capacity, lru: lru, by_identity: by_identity)
        @name = name || "(anonymous)"
        Cache.register(self) if register
      end
    end
  end
end
