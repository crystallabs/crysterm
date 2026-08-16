# The alphabetical `css/**` glob happens to load these before this file, but
# the dependency is structural (`Rule`/`MediaQuery` appear in this file's type
# grammar), so pin the order explicitly.
require "./media_query"
require "./rule"

module Crysterm
  module CSS
    # Layer rank for rules outside any `@layer`. Larger than any real layer rank
    # so unlayered declarations win over layered ones (per the CSS cascade).
    UNLAYERED = 1_000_000

    # Ordered stops of one `@keyframes` block: `{offset 0..1, declarations}`.
    alias KeyframeStops = Array(Tuple(Float64, Hash(String, String)))

    # One `@keyframes` definition: the `@media` guard it was declared under
    # (`nil` = unconditional) and its stops. A name may be defined several
    # times (e.g. a media-gated override after a general definition); the
    # lookup (`Stylesheet#keyframes_for`) picks the last *matching* one.
    alias KeyframeDef = Tuple(MediaQuery?, KeyframeStops)

    # An ordered collection of `Rule`s parsed from CSS text.
    class Stylesheet
      getter rules : Array(Rule)

      # Custom properties (`--name: value`) collected globally, last definition
      # winning. Resolved into `var(--name[, fallback])` references at cascade
      # time. Document-global, not per-element cascaded.
      getter variables : Hash(String, String)

      # Non-fatal diagnostics gathered while parsing — malformed declarations and
      # unknown property names. Parsing never raises; inspect this to surface
      # problems (e.g. `window.stylesheet.try &.warnings`).
      getter warnings : Array(String)

      # Parsed `@keyframes`: animation name -> the definitions seen for it, in
      # source order, each carrying the `@media` guard it was declared under
      # (`nil` = unconditional). Resolve via `#keyframes_for`, which picks the
      # last definition whose guard matches the terminal — a media-gated
      # override must not clobber the general definition on every terminal.
      getter keyframes : Hash(String, Array(KeyframeDef))

      # Whether any rule depends on a widget's *state* via an ancestor-state
      # pseudo-class (e.g. `Form:focus Button`), lowered to a `.state-*` class.
      # The cascade is invalidated on state transitions only when this is set.
      @dynamic_state : Bool = false

      # Whether any rule carries a `:has(...)` relational condition (on the
      # subject or an ancestor). `:has()` is an *upward* relation — its subject
      # can be an ancestor outside a changed widget's subtree — so a scoped
      # incremental restyle can't be trusted; the screen falls back to a full
      # recompute when this is set.
      @has_relational : Bool = false

      # Whether any rule is guarded by an `@media` condition. When set, the
      # screen must re-run the cascade on a terminal resize.
      @has_media : Bool = false

      # Whether any rule declares a geometry/layout property (`width`, `top`,
      # `text-align`, …) — the ones the cascade writes onto the *widget* rather
      # than its `Style`. Hardly any sheet has one, yet finding them costs a
      # re-walk of every winning declaration of every touched widget, so the
      # cascade skips that walk entirely when this is clear.
      @has_geometry : Bool = false

      def initialize(@rules = [] of Rule, @variables = {} of String => String, @warnings = [] of String,
                     @keyframes = {} of String => Array(KeyframeDef))
        # A rule participates in state-driven restyling if a `.state-*` class
        # appears in its structural selector *or* in a `:has()` inner/qualifier —
        # a state carried only inside `:has(... :focus)` must still trigger a
        # recascade on state transitions.
        @dynamic_state = @rules.any? do |r|
          r.selector.includes?(".state-") ||
            r.has.try(&.includes?(".state-")) ||
            r.ancestor_has.try(&.any? { |(qualifier, inner)| qualifier.includes?(".state-") || inner.includes?(".state-") })
        end
        @has_relational = @rules.any? { |r| r.has || r.ancestor_has }
        @has_media = @rules.any?(&.media)
        # Property names are lower-cased at parse, matching `Geometry::PROPERTIES`.
        @has_geometry = @rules.any? do |r|
          r.declarations.any? { |property, _| Geometry.handles?(property) } ||
            r.important.any? { |property, _| Geometry.handles?(property) }
        end
      end

      # :ditto:
      def dynamic_state? : Bool
        @dynamic_state
      end

      # :ditto:
      def has_relational? : Bool
        @has_relational
      end

      # :ditto:
      def has_media? : Bool
        @has_media
      end

      # :ditto:
      def has_geometry? : Bool
        @has_geometry
      end

      # The stops of `@keyframes` *name* on a terminal of *width*×*height*
      # cells with *colors* available at glyph-tier ordinal *glyphs* — the
      # **last** definition whose `@media` guard matches (an unguarded
      # definition always matches), or `nil` when none does. Returns the stored
      # stop arrays themselves, so identity is stable across lookups while the
      # stylesheet (and the matching definition) is unchanged — the animation
      # driver's staleness check relies on that.
      def keyframes_for(name : String, width : Int32, height : Int32, colors : Int32, glyphs : Int32 = 1) : KeyframeStops?
        return unless defs = @keyframes[name]?
        defs.reverse_each do |(mq, stops)|
          return stops if mq.nil? || mq.matches?(width, height, colors, glyphs)
        end
        nil
      end

      # Compiled selectors, memoized by their structural string, so `Node#css`
      # doesn't re-lex/re-compile on each match. A `nil` entry marks an
      # unparseable selector so it isn't retried.
      @compiled_selectors = Cache::Bounded(String, ::CSS::Selector?).new(Cache::SELECTOR_CAPACITY)

      def compiled_selector(selector : String) : ::CSS::Selector?
        @compiled_selectors.fetch(selector) { ::CSS.compile(selector) rescue nil }
      end

      # Per-rule cascade-entry caches, keyed by `{rule index, base_tier}`.
      # A `Rule` is immutable and the `Cascade::Entry` list it contributes is
      # fully determined by the rule plus the tier its sheet occupies, so it's
      # computed once and shared across every cascade for this sheet's lifetime
      # (the cascade only ever `concat`s these arrays, never mutates them).
      # `Cascade.rule_entries`/`selection_entries` own the population.
      getter rule_entries_cache = Hash(Tuple(Int32, Int32), Array(Cascade::Entry)).new
      getter selection_entries_cache = Hash(Tuple(Int32, Int32), Array(Cascade::Entry)).new

      # Maps a state pseudo-class to a `WidgetState`. `:active`, `:selected`
      # and Qt's `:pressed` (a held-down `AbstractButton`, see
      # `AbstractButton#down?`) are treated as synonyms. There is no "blurred"
      # state — style the unfocused look with `:not(:focus)`.
      STATE_PSEUDOS = {
        ":focus"    => WidgetState::Focused,
        ":hover"    => WidgetState::Hovered,
        ":selected" => WidgetState::Selected,
        ":active"   => WidgetState::Selected,
        ":pressed"  => WidgetState::Selected,
        ":disabled" => WidgetState::Disabled,
        ":normal"   => WidgetState::Normal,
      }

      # Standard-CSS state pseudo-classes (Selectors L4) that Crysterm backs with
      # boolean *attributes* rather than `.state-*` classes: `:checked` and
      # `:indeterminate` map to the `[checked]`/`[indeterminate]` attributes
      # widgets emit, and `:enabled` to `:not(:disabled)` (whose inner
      # `:disabled` is then lowered to `.state-disabled`, legal inside `:not()`).
      # Unlike `STATE_PSEUDOS`, these are rewritten textually into every
      # stylesheet, so the idiomatic spelling works natively rather than only in
      # `.qss` translation.
      ATTR_PSEUDOS = {
        "checked"       => "[checked]",
        "indeterminate" => "[indeterminate]",
        "enabled"       => ":not(:disabled)",
      }

      # Matches exactly the `ATTR_PSEUDOS` tokens as whole pseudo-classes (the
      # trailing lookahead keeps `:enabled` from biting into a longer
      # identifier). Case-insensitive, as CSS pseudo-class names are.
      ATTR_PSEUDO = /:(checked|indeterminate|enabled)(?![A-Za-z0-9_-])/i

      # Matches a `::slot` pseudo-element token (`ProgressBar::indicator`),
      # lowered to the *capitalized descendant node* Crysterm emits for that
      # slot. Case-insensitive, as pseudo-element names are.
      SUB_ELEMENT_PSEUDO = /::([a-z][a-z-]*)/i

      # The `:has(` opener, matched case-insensitively (`:HAS(` is legal CSS).
      # Length is fixed at 5 chars regardless of case, so `index + 4` still
      # points at the `(` — the peel/strip helpers rely on that.
      HAS_OPEN = /:has\(/i

      # Mutable state threaded through the recursive parse.
      private class ParseCtx
        getter rules = [] of Rule
        getter variables = {} of String => String
        getter warnings = [] of String
        getter layers = {} of String => Int32
        getter keyframes = {} of String => Array(KeyframeDef)
        property order = 0
        # Mutable so a nested `@import` can resolve relative to the *importing*
        # file's directory (saved/restored around the recursive parse), not the
        # top-level file's.
        property base_path : String?

        def initialize(@base_path = nil)
        end

        # Rank for a named `@layer`, assigned on first appearance (so layers
        # order by declaration order; later layers outrank earlier ones).
        def layer_rank(name : String) : Int32
          layers.fetch(name) { layers[name] = layers.size }
        end
      end

      # Parses a CSS string into a `Stylesheet`. *base_path* (a file or its dir)
      # resolves `@import`.
      #
      # Supports comments, comma-separated selector lists, `prop: value;` blocks,
      # `!important`, custom properties/`var()`, `@media`, `@layer`, `@import`,
      # and native nesting (`A { B { ... } }`, `&`).
      def self.parse(css : String, base_path : String? = nil) : Stylesheet
        ctx = ParseCtx.new(base_path)
        parse_scope(decommented(css), [] of String, nil, UNLAYERED, ctx)
        new ctx.rules, ctx.variables, ctx.warnings, ctx.keyframes
      end

      # Parses a sequence of constructs within one scope. *parents* are the
      # enclosing (already-combined) selectors for native nesting — empty at top
      # level; when non-empty, the scope's direct declarations are emitted as a
      # rule for them.
      private def self.parse_scope(css : String, parents : Array(String), media : MediaQuery?, layer_rank : Int32, ctx : ParseCtx) : Nil
        declarations = {} of String => String
        important = {} of String => String
        pos = 0
        n = css.size
        while pos < n
          pos = skip_ws(css, pos)
          break if pos >= n
          start = pos
          # Read the prelude up to the next top-level `{`/`;`/`}`, skipping
          # parenthesised, bracketed and quoted spans so values like `url(a;b)`
          # and attribute selectors like `[href="a{b}"]` / `[x=a;b]` are safe.
          while pos < n
            ch = css[pos]
            break if ch == '{' || ch == ';' || ch == '}'
            if ch == '('
              pos = Selectors.skip_balanced(css, pos, '(', ')')
            elsif ch == '['
              pos = Selectors.skip_balanced(css, pos, '[', ']')
            elsif ch == '"' || ch == '\''
              pos = Selectors.skip_string(css, pos)
            else
              pos += 1
            end
          end
          # No terminator at end of input: the final construct in a block may
          # omit its trailing `;` (e.g. `{ color: red }`), so flush it as a
          # statement rather than dropping it.
          if pos >= n
            handle_statement(css[start...pos].strip, parents, declarations, important, layer_rank, ctx)
            break
          end
          prelude = css[start...pos].strip
          case css[pos]
          when ';'
            pos += 1
            handle_statement(prelude, parents, declarations, important, layer_rank, ctx)
          when '{'
            close = matching_brace(css, pos)
            body = close ? css[(pos + 1)...close] : css[(pos + 1)..]
            pos = close ? close + 1 : n
            # Flush the scope's own declarations accumulated so far as a rule
            # *before* descending into this nested block, so they get a lower
            # source `order` than the nested rules. Per CSS nesting a parent
            # declaration behaves as if it precedes nested rules, so on an
            # equal-specificity tie a nested (`@media`/`&`) override wins.
            unless parents.empty? || (declarations.empty? && important.empty?)
              emit_rules(parents, declarations, important, media, layer_rank, ctx)
              declarations = {} of String => String
              important = {} of String => String
            end
            handle_block(prelude, body, parents, media, layer_rank, ctx)
          when '}'
            pos += 1 # stray close brace
          end
        end
        emit_rules(parents, declarations, important, media, layer_rank, ctx) unless parents.empty?
      end

      # A `;`-terminated construct: an at-statement (`@import`, `@layer a, b;`)
      # or, inside a rule body, a declaration.
      private def self.handle_statement(prelude : String, parents : Array(String), declarations, important, layer_rank : Int32, ctx : ParseCtx) : Nil
        return if prelude.empty?
        # At-rule names are case-insensitive (`@IMPORT`/`@Layer`); the slice
        # offsets below are by the fixed name length, so they hold for any case.
        if Case.at_rule?(prelude, "import")
          handle_import prelude, layer_rank, ctx
        elsif Case.at_rule?(prelude, "layer")
          prelude[6..].split(',').each { |name| ctx.layer_rank(name.strip) unless name.strip.empty? }
        elsif parents.empty?
          ctx.warnings << "stray content at top level: #{prelude.inspect}"
        else
          parse_declaration prelude, declarations, important, ctx
        end
      end

      # A `{ ... }` block: `@media`, `@layer <name>`, or a style rule (which may
      # itself nest further rules).
      private def self.handle_block(prelude : String, body : String, parents : Array(String), media : MediaQuery?, layer_rank : Int32, ctx : ParseCtx) : Nil
        # At-rule names are case-insensitive (`@MEDIA`/`@Keyframes`); the slice
        # offsets below are by the fixed name length, so they hold for any case.
        if Case.at_rule?(prelude, "keyframes")
          # The enclosing (already AND-combined) `@media` guard applies to the
          # keyframes definition too — registering unconditionally would let a
          # media-gated override clobber the general one on every terminal.
          parse_keyframes prelude[10..].strip, body, media, ctx
        elsif Case.at_rule?(prelude, "media")
          # A nested `@media` ANDs with any enclosing one (CSS Conditional
          # Rules) — the outer guard must keep applying to the inner rules.
          inner = MediaQuery.parse(prelude[6..].strip)
          parse_scope body, parents, (media ? media.and(inner) : inner), layer_rank, ctx
        elsif Case.at_rule?(prelude, "layer")
          name = prelude[6..].strip
          parse_scope body, parents, media, (name.empty? ? layer_rank : ctx.layer_rank(name)), ctx
        else
          parse_scope body, combine_selectors(parents, prelude), media, layer_rank, ctx
        end
      end

      # Parses an `@keyframes name { 0% { … } 50%,75% { … } to { … } }` block into
      # ordered stops (`from`=0%, `to`=100%), registered under *name* together
      # with the enclosing `@media` guard (*media*, `nil` when unconditional).
      # Each stop's declarations are kept raw and resolved by the animation
      # driver; the guard is evaluated at lookup time.
      private def self.parse_keyframes(name : String, body : String, media : MediaQuery?, ctx : ParseCtx) : Nil
        return if name.empty?
        stops = [] of Tuple(Float64, Hash(String, String))
        pos = 0
        n = body.size
        while pos < n
          pos = skip_ws(body, pos)
          break if pos >= n
          start = pos
          while pos < n && body[pos] != '{'
            pos += 1
          end
          break if pos >= n
          selector = body[start...pos].strip
          close = matching_brace(body, pos)
          decl_text = close ? body[(pos + 1)...close] : body[(pos + 1)..]
          pos = close ? close + 1 : n
          decls = {} of String => String
          ignore = {} of String => String
          decl_text.split(';').each do |d|
            d = d.strip
            parse_declaration(d, decls, ignore, ctx) unless d.empty?
          end
          selector.split(',').each do |off|
            keyframe_offset(off.strip).try { |o| stops << {o, decls} }
          end
        end
        return if stops.empty?
        (ctx.keyframes[name] ||= [] of KeyframeDef) << {media, stops.sort_by!(&.[0])}
      end

      # `from`=0, `to`=1, `NN%`=NN/100.
      private def self.keyframe_offset(s : String) : Float64?
        # `from`/`to` are CSS keywords, so case-insensitive (`From`/`TO` are
        # valid keyframe selectors); fold before comparing.
        case Case.fold_keyword(s)
        when "from" then 0.0
        when "to"   then 1.0
        else
          s.ends_with?('%') ? s[0...-1].to_f?.try(&./(100.0)) : nil
        end
      end

      # Combines *parents* with the comma-separated *child* selector list per CSS
      # nesting: `&` is replaced by the parent, otherwise the child becomes a
      # descendant of it.
      private def self.combine_selectors(parents : Array(String), child : String) : Array(String)
        children = child.split(',').map(&.strip).reject(&.empty?)
        return children if parents.empty?
        combined = [] of String
        parents.each do |parent|
          children.each do |part|
            combined << (part.includes?('&') ? part.gsub('&', parent) : "#{parent} #{part}")
          end
        end
        combined
      end

      # Emits one `Rule` per selector with the scope's collected declarations.
      private def self.emit_rules(selectors : Array(String), declarations, important, media : MediaQuery?, layer_rank : Int32, ctx : ParseCtx) : Nil
        return if declarations.empty? && important.empty?
        selectors.each do |selector|
          next if selector.empty?
          # Lower the idiomatic Qt-ish spellings to Crysterm's internal forms
          # first — `::slot` to capitalized descendant nodes, `:checked` to
          # `[checked]`, `:enabled` to `:not(:disabled)` — so everything below
          # operates on the form actually matched.
          selector = lower_sub_elements(selector)
          selector = lower_attr_pseudos(selector)
          # Specificity is from the attr-lowered selector; then the subject's
          # state pseudo / `:has` are peeled, ancestor state pseudos lowered, and
          # types rewritten to classes — per combined selector.
          spec = Specificity.calculate(selector)
          prefix, subject = Selectors.split_subject(selector)
          state, subject = peel_state(subject)
          has, subject = peel_has(subject)
          # `:has(...)` borne by an ancestor compound (`Form:has(.error) Button`)
          # is peeled separately: the engine can't parse `:has`, so it's stripped
          # from the structural prefix and evaluated relationally in the cascade.
          ancestor_has, prefix = peel_ancestor_has(prefix)
          # Lower remaining state pseudos — ancestor ones in the prefix and any
          # nested in the subject (e.g. `:not(:focus)`) — to `.state-*` classes
          # matching the document's stamped state. The subject's own top-level
          # state was already peeled above and carried on the rule.
          structural = Selectors.expand_types(lower_state_pseudos(prefix + subject))
          ctx.rules << Rule.new(structural, declarations, important, state, spec, ctx.order, media, has, layer_rank, ancestor_has)
          ctx.order += 1
        end
      end

      # Loads `@import "file";` (or `@import url(file);`) relative to the base
      # path and parses it inline, so its rules precede — and are overridden
      # by — the importing file's.
      private def self.handle_import(prelude : String, layer_rank : Int32, ctx : ParseCtx) : Nil
        path = prelude[/@import\s+(?:url\()?["']?([^"')]+)["']?\)?/i, 1]?
        return unless path
        base = ctx.base_path
        resolved = base ? File.expand_path(path, File.directory?(base) ? base : File.dirname(base)) : path
        content = begin
          File.read(resolved)
        rescue
          ctx.warnings << "@import: cannot read #{resolved.inspect}"
          return
        end
        # An `@import` *inside* the imported file resolves relative to that
        # file's own directory, so `base_path` points at it for the recursive
        # parse and is restored afterwards for sibling imports in the outer file.
        saved = ctx.base_path
        ctx.base_path = resolved
        begin
          parse_scope decommented(content), [] of String, nil, layer_rank, ctx
        ensure
          ctx.base_path = saved
        end
      end

      private def self.skip_ws(css : String, pos : Int32) : Int32
        while pos < css.size && css[pos].whitespace?
          pos += 1
        end
        pos
      end

      # Index of the `}` matching the `{` at *open*, or `nil` if unbalanced.
      private def self.matching_brace(css : String, open : Int32) : Int32?
        index = Selectors.skip_balanced(css, open, '{', '}')
        index > open && css[index - 1]? == '}' ? index - 1 : nil
      end

      # Resolves `var(...)` references in *value* against *variables*, falling
      # back to the in-call fallback (or empty) for undefined names. Iterates a
      # few times so a variable whose value itself uses `var()` resolves too.
      def self.resolve_var(value : String, variables : Hash(String, String)) : String
        # `var(` is a case-insensitive CSS function name (`VAR(--x)`); the
        # custom-property name inside it stays case-sensitive.
        return value unless value.matches?(Case::VAR_CALL)
        result = value
        4.times do
          replaced = replace_vars(result, variables)
          break if replaced == result
          result = replaced
        end
        result
      end

      # Replaces every `var(--name[, fallback])` reference in *value* in a single
      # left-to-right pass, matching each call's balanced closing paren so a
      # nested `var()` in the fallback (`var(--a, var(--b, red))`) is consumed as
      # one unit — a `[^)]*` regex would stop at the first `)`, leaving a stray
      # `)` once the outer name resolves. A defined name takes its value and
      # drops the fallback; an undefined one falls back (possibly itself a
      # `var()`, resolved on the next `resolve_var` iteration), else empty.
      private def self.replace_vars(value : String, variables : Hash(String, String)) : String
        idx = value.index(Case::VAR_CALL)
        return value unless idx
        open = idx + 3 # index of the '('
        close = Selectors.matching_paren(value, open)
        return value unless close
        inner = value[(open + 1)...close]
        comma = Selectors.top_level_comma(inner)
        name = (comma ? inner[0...comma] : inner).strip
        fallback = comma ? inner[(comma + 1)..].strip : nil
        replacement = if defined = variables[name]?
                        defined
                      elsif fallback
                        fallback
                      else
                        ""
                      end
        value[0...idx] + replacement + replace_vars(value[(close + 1)..], variables)
      end

      # Parses a stylesheet from a `.css` file (its path is used to resolve
      # `@import`).
      def self.from_file(path : String | Path) : Stylesheet
        source = File.read(path)
        # `.qss` (Qt Style Sheet) files are translated to Crysterm CSS first.
        # Unmapped selectors fall through to the tolerant parser.
        source = Qss.to_css(source) if path.to_s.downcase.ends_with?(".qss")
        parse source, base_path: path.to_s
      end

      # Strips `/* ... */` comments (including multi-line), honoring quoted
      # strings: a `/*` inside `"…"`/`'…'` — a `url()` path, an
      # attribute-selector value, a glyph string — is content, not a comment
      # opener, so quoted spans are copied through verbatim. Each comment outside
      # them becomes a single space; an unterminated comment runs to end of
      # input, per CSS tokenization.
      private def self.decommented(css : String) : String
        return css unless css.includes?("/*")
        String.build(css.bytesize) do |io|
          i = 0
          n = css.size
          while i < n
            ch = css[i]
            if ch == '"' || ch == '\''
              j = Selectors.skip_string(css, i)
              io << css[i...j]
              i = j
            elsif ch == '/' && css[i + 1]? == '*'
              close = css.index("*/", i + 2)
              io << ' '
              i = close ? close + 2 : n
            else
              io << ch
              i += 1
            end
          end
        end
      end

      # Parses a single `prop: value` declaration into *declarations*/*important*
      # (or *variables* for a `--custom` property). Custom-property names are
      # case-sensitive; other names are lower-cased. A trailing `!important`
      # routes the declaration to the important hash.
      private def self.parse_declaration(text : String, declarations : Hash(String, String), important : Hash(String, String), ctx : ParseCtx) : Nil
        unless text.includes?(':')
          ctx.warnings << "malformed declaration (missing ':'): #{text.inspect}"
          return
        end
        name, _, value = text.partition(':')
        name = name.strip
        value = value.strip
        if name.empty? || value.empty?
          ctx.warnings << "malformed declaration: #{text.inspect}"
          return
        end
        if name.starts_with?("--")
          # A custom property may carry a trailing `!important`, but the value
          # `var(--name)` substitutes must not include the marker, or every
          # consumer inherits a bogus `red !important` that fails to parse.
          if m = value.match(IMPORTANT_RE)
            value = m.pre_match.rstrip
          end
          ctx.variables[name] = value # custom property, case-sensitive name
          return
        end
        name = name.downcase
        ctx.warnings << "unknown property: #{name.inspect}" unless Properties.known?(name)
        # CSS permits whitespace between `!` and `important` (`red ! important`),
        # so match tolerantly rather than testing a fixed suffix.
        if m = value.match(IMPORTANT_RE)
          important[name] = m.pre_match.rstrip
        else
          declarations[name] = value
        end
      end

      # Trailing `!important` marker, tolerant of interior whitespace (and case),
      # anchored to the end of the value.
      IMPORTANT_RE = /!\s*important\s*\z/i

      # State pseudo-class tokens, longest first, so a longer token is matched
      # before any shorter token it contains as a substring.
      STATE_PSEUDOS_BY_LENGTH = STATE_PSEUDOS.to_a.sort_by! { |(token, _)| -token.size }

      # Precompiled matchers for `lower_state_pseudos`, one per state pseudo
      # (longest token first). Each pairs a boundary-anchored regex — leading
      # `:` bounds the start, negative lookahead forbids a trailing identifier
      # char so `:focus` can't match inside `:focus-within` — with the
      # `.state-*` class it lowers to.
      STATE_PSEUDO_MATCHERS = STATE_PSEUDOS_BY_LENGTH.map do |(token, state)|
        # Pseudo-class names are case-insensitive (`:HOVER` == `:hover`); the
        # matcher rewrites only the `:state` token, leaving the rest of the
        # selector (type names etc.) and its casing untouched.
        {Regex.new(Regex.escape(token) + "(?![A-Za-z0-9_-])", Regex::Options::IGNORE_CASE), ".#{state.css_class}"}
      end

      # Splits a state pseudo-class off a selector, returning `{state,
      # structural_selector}`. Only a top-level pseudo (outside any `[...]`
      # attribute value or `(...)` functional-pseudo argument) that stands as a
      # complete token — not a prefix of a longer pseudo such as
      # `:focus-within` — is treated as the subject's state; nested ones are
      # left for `lower_state_pseudos`. Only the first recognized pseudo-class
      # is peeled (a single subject-anchored state pseudo per selector).
      private def self.peel_state(selector : String) : Tuple(WidgetState?, String)
        return {nil, selector} unless selector.includes?(':') # fast path: no pseudo at all
        STATE_PSEUDOS_BY_LENGTH.each do |(token, state)|
          if idx = top_level_pseudo_index(selector, token)
            structural = (selector[0...idx] + selector[(idx + token.size)..]).strip
            structural = "*" if structural.empty?
            return {state, structural}
          end
        end
        {nil, selector}
      end

      # Index of the first occurrence of *token* in *selector* that is at the top
      # level (depth 0 w.r.t. `[]`/`()`) and bounded as a complete pseudo-class
      # (following char, if any, is not an identifier char, so `:focus` never
      # matches inside `:focus-within`), or `nil`.
      private def self.top_level_pseudo_index(selector : String, token : String) : Int32?
        depth = 0
        last = selector.size - token.size
        i = 0
        while i <= last
          case selector[i]
          when '"', '\''
            i = Selectors.skip_string(selector, i) # skip quoted spans so `:x` inside them isn't peeled
            next
          when '[', '(' then depth += 1
          when ']', ')' then depth -= 1
          else
            # Pseudo-class names are case-insensitive (`:HOVER` == `:hover`);
            # the rest of the selector (type names, ids, classes) is not.
            if depth == 0 && selector[i, token.size].compare(token, case_insensitive: true) == 0 && !ident_char?(selector[i + token.size]?)
              return i
            end
          end
          i += 1
        end
        nil
      end

      # Whether *char* can appear inside a CSS identifier (so a state token
      # followed by one is really part of a longer pseudo-class). `nil` (end of
      # string) is a boundary, not an identifier char.
      private def self.ident_char?(char : Char?) : Bool
        char ? Selectors.ident?(char) : false
      end

      # The `:has(...)` inner (relative) selector carried between *open* (the
      # `(`) and *close* (the `)`) in *source*: the trimmed body, anchored at
      # `:scope` when it leads with a combinator (`> .x` / `+ .x` / `~ .x`) so
      # the relational match is rooted at the subject.
      private def self.has_inner(source : String, open : Int32, close : Int32) : String
        inner = source[(open + 1)...close].strip
        inner.starts_with?('>') || inner.starts_with?('+') || inner.starts_with?('~') ? ":scope #{inner}" : inner
      end

      # Splits a `:has(...)` relational pseudo-class off the (subject) selector,
      # returning `{inner_selector, remaining}`. The inner selector is
      # type-expanded for matching against a node's subtree; a leading
      # combinator (`> .x`) is anchored with `:scope`. Only the first `:has` is
      # handled; the `html5` engine has no `:has`, so the cascade evaluates it.
      private def self.peel_has(selector : String) : Tuple(String?, String)
        idx = selector.index(HAS_OPEN)
        return {nil, selector} unless idx
        open = idx + 4 # index of '('
        close = Selectors.matching_paren(selector, open)
        return {nil, selector} unless close

        inner = has_inner(selector, open, close)
        remaining = (selector[0...idx] + selector[(close + 1)..]).strip
        remaining = "*" if remaining.empty?
        # Lower any state pseudo inside the `:has()` inner (`:has(Input:focus)`
        # -> `:has(Input.state-focused)`) — the `html5` engine can't parse
        # `:focus` and would raise (making the rule never match), but the
        # document stamps `.state-*` classes that a lowered selector matches.
        {Selectors.expand_types(lower_state_pseudos(inner)), remaining}
      end

      # Peels every `:has(...)` borne by an *ancestor* compound out of *prefix*
      # (the part of the selector before the subject), returning
      # `{conditions, prefix_without_has}`, each condition a
      # `{qualifier, inner}` pair. The structural prefix has all `:has(...)`
      # stripped (the `html5` engine can't parse it); it's re-applied
      # relationally in the cascade.
      private def self.peel_ancestor_has(prefix : String) : Tuple(Array(Tuple(String, String))?, String)
        return {nil, prefix} unless prefix.matches?(HAS_OPEN)
        conditions = [] of Tuple(String, String)
        search = 0
        while idx = prefix.index(HAS_OPEN, search)
          open = idx + 4 # index of '('
          close = Selectors.matching_paren(prefix, open)
          break unless close
          inner = has_inner(prefix, open, close)
          # The qualifier matches the ancestor: everything up to the end of the
          # compound bearing this `:has`, with `:has(...)` removed and types
          # lowered as the structural selector is.
          compound_end = Selectors.compound_end_index(prefix, close + 1)
          qualifier = Selectors.expand_types(lower_state_pseudos(strip_has(prefix[0...compound_end]))).strip
          # Lower state pseudos in the inner too: the engine can't parse
          # `:focus`, but the document carries `.state-*`.
          conditions << {qualifier, Selectors.expand_types(lower_state_pseudos(inner))} unless qualifier.empty?
          search = close + 1
        end
        {conditions.empty? ? nil : conditions, strip_has(prefix)}
      end

      # Removes every `:has(...)` span from *selector* (the `html5` engine can't
      # parse `:has`; it's evaluated relationally in the cascade instead).
      private def self.strip_has(selector : String) : String
        result = selector
        while idx = result.index(HAS_OPEN)
          open = idx + 4
          close = Selectors.matching_paren(result, open)
          break unless close
          result = result[0...idx] + result[(close + 1)..]
        end
        result
      end

      # Lowers state pseudo-classes still present in *selector* (ancestor ones in
      # the prefix, and any nested in the subject like `:not(:focus)`) into
      # `.state-*` classes (e.g. `Form:focus ` -> `Form.state-focused `), so they
      # match against the live document's stamped state classes. Each token is
      # matched only as a complete pseudo-class, so `:focus` is not torn out of
      # `:focus-within`.
      private def self.lower_state_pseudos(selector : String) : String
        return selector unless selector.includes?(':') # fast path: no pseudo at all
        result = selector
        STATE_PSEUDO_MATCHERS.each { |(re, repl)| result = result.gsub(re, repl) }
        result
      end

      # Rewrites the standard-CSS `:checked`/`:indeterminate`/`:enabled`
      # pseudo-classes into the attribute/`:not()` forms Crysterm matches
      # against. Must run on the whole selector before specificity/state
      # peeling, so the rewrite is uniform across prefix and subject and
      # specificity is computed on the form actually matched — an attribute and
      # a pseudo-class weigh the same.
      private def self.lower_attr_pseudos(selector : String) : String
        return selector unless selector.includes?(':') # fast path: no pseudo at all
        selector.gsub(ATTR_PSEUDO) { ATTR_PSEUDOS[$1.downcase] }
      end

      # Sub-control spellings that alias an existing slot rather than naming
      # their own node: `::handle`/`::thumb` are the conventional names for what
      # Crysterm exposes as the `indicator` node, so `Slider::handle { glyph:
      # "█" }` lands in the `indicator` sub-style.
      SUB_ELEMENT_ALIASES = {
        "handle" => "indicator",
        "thumb"  => "indicator",
      }

      # Rewrites `Type::slot` pseudo-elements into the capitalized descendant node
      # Crysterm matches a slot by: `ProgressBar::indicator` -> `ProgressBar
      # Indicator`, which `expand_types` turns into the `.Indicator` class on the
      # slot node. A `::name` with no backing slot becomes a class matching
      # nothing. Must run before `expand_types`, which otherwise keeps `::name`
      # verbatim as an inert pseudo-element.
      private def self.lower_sub_elements(selector : String) : String
        return selector unless selector.includes?("::")
        selector.gsub(SUB_ELEMENT_PSEUDO) do
          name = $1.downcase
          " #{SUB_ELEMENT_ALIASES.fetch(name, name).capitalize}"
        end
      end
    end
  end
end
