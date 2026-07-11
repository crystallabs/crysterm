module Crysterm
  # Central home for Crysterm's caches.
  #
  # Crysterm memoizes many computed results (loaded fonts, converted colors,
  # decoded images, per-widget layout/attr memos, …). This module provides the
  # shared machinery for that — a bounded, self-evicting cache type
  # (`Cache::Bounded`) and a registry that makes every *process-wide* cache
  # introspectable and clearable from one place — plus the single catalog of
  # size caps (below), so tuning any cache means editing this file.
  #
  # ## What lives here vs. what stays put
  #
  # * **Process-wide caches** (shared across the whole run — fonts, color
  #   conversions, image decodes) are *defined* here as module-level instances
  #   and register themselves, so `Cache.stats` / `Cache.clear_all` see them.
  # * **Per-instance caches** (a memo tied to one widget/painter/document) must
  #   stay with their instance — their whole correctness model is that they live,
  #   invalidate, and die with that instance. They can still opt into
  #   `Cache::Bounded` for a size cap (reading their cap from a `*_CAPACITY`
  #   constant here), but they do **not** register globally: tracking thousands
  #   of short-lived instance caches in a process-global list would leak them.
  #
  # ## Catalog of caps
  #
  # Every cache's entry cap is a constant here, so this file is the one place to
  # see and tune them. `0` (or any non-positive value) means "unbounded".
  module Cache
    # -- Capacity catalog ------------------------------------------------------
    #
    # Process-wide caches (defined in this file):

    # `Font.load` — loaded bitmap faces, keyed by path+weight. A handful at most.
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
    # every cascade/`bg` change; the cap is a generous ceiling it should never
    # reach in practice.
    MENU_SURFACE_CAPACITY = 512

    # `Widget::ListTable` CSS-row derived styles (`css_without_border` /
    # `css_alt_overlay`) — source `Style` → derived `Style`, keyed by identity.
    # Bounded by the table's row count and dropped when the cascade replaces the
    # widget's styles; the cap is a generous ceiling.
    LISTTABLE_ROW_CAPACITY = 1024

    # -- Registry --------------------------------------------------------------

    # The introspectable interface a registered cache exposes. Any cache that
    # registers (see `Bounded.new(register: true)`) can be enumerated, sized,
    # and cleared through `Cache`.
    module Registered
      abstract def cache_name : String
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
        {name: c.cache_name, size: c.size, capacity: c.capacity}
      end
    end

    # A size-bounded memoization cache: a `Hash` that evicts entries once it
    # grows past *capacity*.
    #
    # Drop-in for a plain `Hash` used as a memo (`[]`, `[]?`, `[]=`, `has_key?`,
    # `delete`, `clear`, `fetch`), with two additions:
    #
    # * **Eviction.** When adding an entry would exceed *capacity*, the oldest
    #   entry is dropped (FIFO by default; strict LRU with `lru: true`). A
    #   *capacity* of `0` or less means unbounded.
    # * **Memoizing `fetch`.** `fetch(key) { compute }` stores and returns the
    #   computed value on a miss (and correctly caches a `nil` value, so it works
    #   for negative caching). This differs from `Hash#fetch`, which does *not*
    #   store.
    #
    # Eviction is FIFO by default because most memo caches are small and hot:
    # FIFO keeps reads as pure `Hash` lookups (no reordering), preserving
    # hot-path performance. Pass `lru: true` when recency-of-use should decide
    # what survives (e.g. an image decode cache) and the read cost is affordable.
    #
    # Not thread-safe, matching the plain hashes it replaces — Crysterm's caches
    # are touched from the single event loop.
    class Bounded(K, V)
      include Registered

      # A human-readable name (shown by `Cache.stats`); `"(anonymous)"` when
      # constructed without one.
      getter cache_name : String

      # Maximum entries kept; `<= 0` means unbounded.
      property capacity : Int32

      # Creates a cache holding at most *capacity* entries.
      #
      # *name* labels it for `Cache.stats`. *register* adds it to the global
      # `Cache` registry — do this for process-wide caches, never for
      # per-instance ones (they would accumulate and leak). *lru* switches
      # eviction from FIFO to least-recently-used. *by_identity* keys the cache
      # on object identity (`same?`) instead of value equality — for caches
      # memoizing per-object results (e.g. a `Style` instance → its rendered
      # output), mirroring `Hash#compare_by_identity`.
      def initialize(@capacity : Int32, name : String? = nil, *, register : Bool = false, @lru : Bool = false, by_identity : Bool = false)
        @store = {} of K => V
        @store.compare_by_identity if by_identity
        @cache_name = name || "(anonymous)"
        Cache.register(self) if register
      end

      # Current number of entries.
      def size : Int32
        @store.size
      end

      # Whether *key* is present (distinguishes a cached `nil` value from absence).
      def has_key?(key : K) : Bool
        @store.has_key? key
      end

      # The value for *key*, or `nil` if absent. In `lru` mode a hit is promoted
      # to most-recently-used.
      def []?(key : K) : V?
        return nil unless @store.has_key? key
        touch key
      end

      # The value for *key*; raises `KeyError` if absent (like `Hash#[]`).
      def [](key : K) : V
        raise KeyError.new("Missing cache key: #{key.inspect}") unless @store.has_key? key
        touch key
      end

      # Stores *value* under *key* and returns it, evicting if over capacity.
      def []=(key : K, value : V) : V
        @store[key] = value
        evict!
        value
      end

      # Returns the cached value for *key*, or computes it via the block, stores
      # it, and returns it. The block's result is cached even when `nil`.
      def fetch(key : K, & : -> V) : V
        if @store.has_key? key
          touch key
        else
          self[key] = yield
        end
      end

      # Removes *key*, returning its value or `nil`.
      def delete(key : K) : V?
        @store.delete key
      end

      # Empties the cache.
      def clear : Nil
        @store.clear
      end

      # Yields each `{key, value}` pair (insertion order).
      def each(& : Tuple(K, V) -> _) : Nil
        @store.each { |k, v| yield({k, v}) }
      end

      # Reads *key*'s value, promoting it in `lru` mode. Caller guarantees the
      # key is present.
      private def touch(key : K) : V
        value = @store[key]
        if @lru
          @store.delete key
          @store[key] = value
        end
        value
      end

      # Drops oldest entries until within capacity.
      private def evict! : Nil
        return unless @capacity > 0
        while @store.size > @capacity
          oldest = @store.first_key?
          break if oldest.nil?
          @store.delete oldest
        end
      end
    end
  end
end
