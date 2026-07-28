module Crysterm
  module CSS
    # A parsed `@media` condition: a logical **OR** of comma-separated queries,
    # each a **conjunction** (AND) of feature tests, evaluated against the
    # terminal's size, color depth and glyph support tier. Only width/height,
    # `min-colors`/`max-colors` and `glyphs`/`min-glyphs`/`max-glyphs` features
    # are supported.
    #
    # A comma in a media query is an OR of full queries (`@media (max-width: 40),
    # (min-width: 100)` matches a narrow *or* a wide terminal), so each
    # comma-separated group is stored and evaluated independently — AND-ing them
    # all would make such a list unsatisfiable.
    struct MediaQuery
      # One entry per comma-separated query: its AND-ed feature conditions paired
      # with whether that query is satisfiable at all. A non-empty query that
      # yields no recognizable numeric feature — a media type (`print`), an
      # unknown or non-integer feature (`(prefers-color-scheme: dark)`,
      # `(orientation: portrait)`) — is *unmatchable* rather than vacuously true.
      # Without this, the empty conjunction (`[].all?` is `true`) would apply the
      # guarded rule at every terminal, inverting the author's intent.
      getter groups : Array(Tuple(Array(Tuple(String, Int32)), Bool))

      def initialize(@groups)
      end

      # All feature conditions across every comma-separated group, flattened.
      def conditions : Array(Tuple(String, Int32))
        groups.flat_map { |(conds, _)| conds }
      end

      # Whether the query is satisfiable at all — true when *any* group is
      # (comma-separated queries are OR-ed).
      def matchable? : Bool
        groups.any? { |(_, ok)| ok }
      end

      # The conjunction of this query with *other*: matches exactly when both
      # do. Used for nested `@media` (per CSS Conditional Rules the inner query
      # ANDs with the enclosing one). Each query is an OR of AND-groups, so the
      # conjunction is the cross-product: every pairing of an outer group with
      # an inner group concatenates their conditions into one group, satisfiable
      # only when both sides are (an unmatchable side — `not`, `print`, an
      # unknown feature — poisons every group it appears in, matching
      # `A AND false = false`). Identical repeated conditions are dropped.
      def and(other : MediaQuery) : MediaQuery
        combined = groups.flat_map do |(conds, ok)|
          other.groups.map { |(oconds, ook)| {(conds + oconds).uniq, ok && ook} }
        end
        MediaQuery.new combined
      end

      # The numeric media features crysterm understands (cell counts / color
      # depth / glyph-tier ordinals). Any other `(feature: …)` group marks the
      # whole query unmatchable.
      FEATURES = {"min-width", "max-width", "min-height", "max-height", "min-colors", "max-colors",
                  "glyphs", "min-glyphs", "max-glyphs"}

      # Matches one `(feature: value)` group. Feature names fold to lowercase
      # (CSS media features are case-insensitive), and a trailing unit
      # (`px`, `em`, `%`, …) on the integer value is tolerated and ignored:
      # crysterm features are in cell counts, but authors porting CSS habits
      # write `(max-width: 40px)`.
      FEATURE_RE = /\(\s*([a-z-]+)\s*:\s*(\d+)[a-z%]*\s*\)/i

      # Matches any parenthesized group, so an unrecognized feature (one that
      # `FEATURE_RE` can't parse) can be detected and mark the query unmatchable.
      GROUP_RE = /\([^()]*\)/

      # Matches a `(glyphs: <tier>)` / `(min-glyphs: …)` / `(max-glyphs: …)`
      # group whose value is a support-tier keyword. The tier is stored as its
      # ordinal (ascii 0 < unicode 1 < extended 2), so the conditions ride the
      # same `{feature, Int32}` tuples as the numeric features; a bare ordinal
      # via `FEATURE_RE` works too.
      GLYPHS_FEATURE_RE = /\(\s*((?:min-|max-)?glyphs)\s*:\s*(ascii|unicode|extended)\s*\)/i

      # Parses a condition string such as `(min-width: 80) and (max-width: 120)`,
      # or a comma-separated OR list like `(max-width: 40), (min-width: 100)`.
      # Media feature values are integers, so a top-level comma only ever
      # separates whole queries — never appears inside a `(feature: value)`.
      def self.parse(condition : String) : MediaQuery
        groups = condition.split(',').map do |query|
          conditions = [] of Tuple(String, Int32)
          matchable = true
          query.scan(GROUP_RE) do |group|
            if m = group[0].match(FEATURE_RE)
              feature = m[1].downcase
              # `to_i?` (not `to_i`): a value beyond Int32 range would raise
              # `OverflowError` out of a parse that never raises. It falls
              # through to the unmatchable path below instead.
              if FEATURES.includes?(feature) && (value = m[2].to_i?)
                conditions << {feature, value}
                next
              end
            end
            # A glyph-tier feature with a keyword value (`(glyphs: ascii)`),
            # stored as the tier's ordinal.
            if (m = group[0].match(GLYPHS_FEATURE_RE)) && (tier = Glyphs::Tier.parse?(m[2]))
              conditions << {m[1].downcase, tier.value.to_i32}
              next
            end
            # A `(...)` group that isn't a known numeric feature (e.g.
            # `(orientation: portrait)`) makes this query unmatchable.
            matchable = false
          end
          # Scan the text *outside* the `(...)` groups: the media type and
          # logical keywords. A featureless query must be decided here, not
          # rejected above — `@media screen`/`@media all` is legitimate and a
          # terminal satisfies it. `not` inverts the whole query, which crysterm
          # can't represent, so it is unmatchable rather than applying the
          # un-negated (inverted) meaning. An unsupported media type
          # (`print`/`speech`/…) never matches a terminal either.
          query.gsub(GROUP_RE, ' ').split.each do |word|
            case word.downcase
            when "and", "only", "screen", "all"
              # connector, or a media type a terminal satisfies: no effect
            else
              # `not`, or a media type we don't match (`print`/`speech`/…)
              matchable = false
            end
          end
          {conditions, matchable}
        end
        new groups
      end

      # Whether this query matches a terminal of *width*×*height* cells with
      # *colors* available at glyph-tier ordinal *glyphs* (defaults to Unicode,
      # the toolkit default tier) — true when **any** comma-separated group
      # matches (OR), each group requiring **all** its conditions (AND).
      # `glyphs:` is an exact tier match; `min-`/`max-` range over the tier
      # ordering ascii(0) < unicode(1) < extended(2).
      def matches?(width : Int32, height : Int32, colors : Int32, glyphs : Int32 = 1) : Bool
        groups.any? do |(conditions, matchable)|
          next false unless matchable
          conditions.all? do |(feature, value)|
            case feature
            when "min-width"  then width >= value
            when "max-width"  then width <= value
            when "min-height" then height >= value
            when "max-height" then height <= value
            when "min-colors" then colors >= value
            when "max-colors" then colors <= value
            when "glyphs"     then glyphs == value
            when "min-glyphs" then glyphs >= value
            when "max-glyphs" then glyphs <= value
            else
              # Unreachable today: `.parse` stores only `FEATURES` (plus the
              # glyph tiers), all matched above. Fail *closed* — if the parser
              # ever learns a feature this matcher doesn't, its rules must not
              # silently apply everywhere (R-86).
              false
            end
          end
        end
      end
    end
  end
end
