module Crysterm
  module CSS
    # The single home for crysterm's CSS *case-folding policy*.
    #
    # CSS is case-insensitive in most of its grammar but case-*sensitive* in a
    # handful of important spots, and every parse site used to re-decide the rule
    # independently — which is exactly how case bugs crept in (one site folding,
    # the next forgetting). This module pins the policy in one documented place;
    # new parse sites should reach for these helpers rather than sprinkling their
    # own `.downcase`/`/i`.
    #
    # ## Case-*insensitive* (fold before comparing)
    #
    # * keywords / value-keywords — `none`, `hidden`, `bold`, `dashed`, `auto`,
    #   `infinite`, `ease-in-out`, … (`fold_keyword`)
    # * property names — `COLOR` == `color`, `Border-Width` == `border-width`
    #   (`fold_property`)
    # * unit tokens — `10PX`, `VW`, `MS` (`fold_unit`)
    # * function names — `VAR(` == `var(` (`VAR_CALL`)
    # * at-rule names — `@MEDIA`, `@Layer`, `@Import` (`at_rule?`)
    # * pseudo-class names — `:FOCUS` == `:focus` (folded at the two selector
    #   sites in `Stylesheet`, which use a `/i` regex and a case-insensitive
    #   `String#compare` — see those call sites)
    #
    # ## Case-*sensitive* (MUST NOT be folded)
    #
    # * type selectors / widget names — the PascalCase `Button` is **not** the
    #   lowercase `button`
    # * custom-property names — `--Foo` and `--foo` are distinct variables
    # * string values, `url(...)` paths
    # * attribute / id / class values
    #
    # When in doubt: the *names of CSS grammar tokens* fold; the *author-chosen
    # identifiers and literals they carry* do not.
    module Case
      # Lower-cases *s* for case-insensitive comparison, but returns *s* itself
      # (no allocation) when it is already folded. `String#downcase` always
      # builds a fresh `String` even when nothing changes, and these helpers run
      # in the cascade's per-declaration inner loop (`Properties.apply` folds
      # every property name, and the value parsers fold every keyword/unit) over
      # CSS tokens that are *already* lowercase ASCII in the overwhelming common
      # case (`color`, `background-color`, `none`, `px`, …). Scanning for a byte
      # that `downcase` could change — an ASCII `A`-`Z`, or any non-ASCII byte —
      # and returning *s* unchanged when none is found is byte-for-byte identical
      # to `downcase` (a pure-ASCII string with no uppercase is its own
      # lower-cased form) while skipping the allocation.
      private def self.folded_or_self(s : String) : String
        s.each_byte do |b|
          return s.downcase if (b >= 0x41 && b <= 0x5A) || b >= 0x80
        end
        s
      end

      # Folds a CSS keyword / value-keyword for comparison (`NONE` -> `none`).
      # Does not strip — callers that need to trim whitespace do so themselves.
      def self.fold_keyword(s : String) : String
        folded_or_self s
      end

      # Folds a property name for comparison, but leaves a custom property
      # (`--Foo`) untouched: custom-property names are case-*sensitive*.
      def self.fold_property(name : String) : String
        name.starts_with?("--") ? name : folded_or_self(name)
      end

      # Folds a unit token (`PX` -> `px`, `VW` -> `vw`).
      def self.fold_unit(s : String) : String
        folded_or_self s
      end

      # Case-insensitive `@<name>` prefix test (*name* given without the `@`):
      # `at_rule?("@MEDIA ...", "media")` is true. At-rule *names* are
      # case-insensitive; the slice offsets callers use afterward are by the
      # (fixed) name length, so they hold for any casing.
      def self.at_rule?(prelude : String, name : String) : Bool
        prelude.downcase.starts_with?("@#{name}")
      end

      # Matches a `var(` function-call opener, case-insensitively (CSS function
      # names are case-insensitive, so `VAR(--x)` is a `var()` call). The opener
      # is always 4 chars (`v a r (`) regardless of case, so a matched start
      # index + 3 is still the `(`. The custom-property name *inside* the call
      # stays case-sensitive.
      VAR_CALL = /var\(/i
    end
  end
end
