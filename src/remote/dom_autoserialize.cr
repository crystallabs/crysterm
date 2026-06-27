module Crysterm
  module DOM
    # Initializer arg names owned by the base handler, or structural /
    # interaction flags that aren't serializable layout content — skipped by the
    # automatic scan below.
    BASE_KEYS = %w[
      left top right bottom width height name content parse_tags wrap_content
      align overflow style styles visible scrollable input focused children
      index resizable fixed draggable keys vi mouse layout layout_hint
      scrollbar track always_scroll focus_on_click hover_text label parent screen
    ]
  end
end

# Automatic per-widget option (de)serialization — no opt-in required.
#
# Every `Crysterm::Widget` subclass is serializable by virtue of its namespace
# (see `dom_loader.cr` for the matching auto-registration). This generates each
# widget's `#dom_attributes` / `#dom_apply` by scanning its **initializer
# arguments**: every arg whose backing instance variable is exactly a supported
# type — `Bool`, `String`, `Int32`, the `Int32 | String | Nil` dimension union,
# or their nilable forms — is emitted and loaded automatically.
#
# Mechanics:
#  * Generated on *every concrete `Widget` subclass* (the `JSON::Serializable`
#    pattern), so each gets its own specialization — necessary because the
#    methods are reached through *virtual* dispatch (`Widget#to_layout_html`, the
#    DOM loader), under which an inherited branch-root method would run with
#    `@type` pinned to the branch root and so miss a deeper subclass's own
#    options. The scan body is `{% verbatim %}` so `@type.instance_vars` is
#    deferred to method-compile time (it isn't available at `macro finished`).
#    The base `Widget` keeps its hand-curated handler for the universal options,
#    reached via `super`.
#  * The scan walks `[@type] + @type.ancestors`, so a widget also serializes
#    options it inherits; `BASE_KEYS` excludes the universal/structural ones.
#  * Types are matched precisely via `union_types` (so e.g. `Array(String)` or an
#    enum is left alone, not mistaken for `String`).
#  * A widget that hand-writes its own `#dom_attributes`/`#dom_apply` (e.g.
#    `List`) is skipped here — that opts it out.
#
# The two generated methods share one compile-time scan, hosted in
# `dom_autoserialize_body` below: each method's `verbatim` block emits a single
# call to it (with the `mode` that selects the right body), so the
# instance-var/initializer-arg collection can't drift between them. The call is
# expanded inside the `verbatim` so it re-resolves per *concrete* widget (where
# `@type` is that widget). The round-trip invariant spec exercises every
# registered widget as a backstop.

# Emits the body of a generated `#dom_attributes` (`mode == :attributes`) or
# `#dom_apply` (`mode == :apply`). The `supported`/`names` collection that
# precedes the mode-specific emission is identical for both; see the
# file-level comment for why it lives here rather than inline in each method.
macro dom_autoserialize_body(mode)
  {% begin %}
    {% supported = {} of Nil => Nil %}
    {% for iv in @type.instance_vars %}
      {% nn = iv.type.union_types.map(&.stringify).reject { |x| x == "Nil" } %}
      {% kind = nn == ["Bool"] ? "bool" : (nn == ["Int32"] ? "int" : (nn == ["String"] ? "str" : (nn.sort == ["Int32", "String"] ? "dim" : nil))) %}
      {% supported[iv.name.stringify] = {kind, iv.type.union_types.map(&.stringify).includes?("Nil")} if kind %}
    {% end %}
    {% names = [] of Nil %}
    {% defaults = {} of Nil => Nil %}
    {% for anc in [@type] + @type.ancestors %}
      {% for m in anc.methods.select { |x| x.name == "initialize" } %}
        {% for a in m.args %}
          {% n = a.name.stringify %}
          {% if supported[n] && !::Crysterm::DOM::BASE_KEYS.includes?(n) && !names.includes?(n) %}
            {% names << n %}
            # Record the initializer-arg default (the most-derived initializer
            # wins, matching `names`' dedup). A default-`true` `Bool` must be
            # emitted as `"false"` when cleared — emitting nothing (the old
            # behavior) silently reverted it to `true` on reload, since `#dom_apply`
            # only runs for attributes that are present.
            {% defaults[n] = a.default_value %}
          {% end %}
        {% end %}
      {% end %}
    {% end %}
    {% if mode == :attributes %}
      {% for n in names %}
        {% kind = supported[n][0] %}{% key = n.split("_").join("-") %}
        {% if kind == "bool" %}
          {% if defaults[n] && defaults[n].stringify == "true" %}
            # Defaults to `true`: emit only when cleared (so the value round-trips).
            attrs[{{ key }}] = "false" unless @{{ n.id }}
          {% else %}
            # Defaults to `false` (or no/non-literal default): emit only when set.
            attrs[{{ key }}] = "true" if @{{ n.id }}
          {% end %}
        {% elsif kind == "str" %}
          (@{{ n.id }}).try { |s| attrs[{{ key }}] = s unless s.empty? }
        {% else %}
          (@{{ n.id }}).try { |v| attrs[{{ key }}] = v.to_s }
        {% end %}
      {% end %}
    {% else %}
      case key
      {% for n in names %}
        {% kind = supported[n][0] %}{% nilable = supported[n][1] %}{% key = n.split("_").join("-") %}
        when {{ key }}
          {% if kind == "bool" %}
            @{{ n.id }} = (value == "true")
          {% elsif kind == "dim" %}
            @{{ n.id }} = dom_coerce_dimension(value)
          {% elsif kind == "int" %}
            {% if nilable %}
              @{{ n.id }} = value.try(&.to_i?)
            {% else %}
              value.try(&.to_i?).try { |i| @{{ n.id }} = i }
            {% end %}
          {% else %} # str
            @{{ n.id }} = {% if nilable %}value{% else %}value || ""{% end %}
          {% end %}
      {% end %}
      else
        return super
      end
    {% end %}
  {% end %}
end

macro finished
  {% for t in Crysterm::Widget.all_subclasses %}
    # Generate on EVERY concrete widget, not just the direct children of Widget.
    # A verbatim body re-resolves @type to the concrete widget only when the
    # method is invoked on a statically-known concrete receiver; under the
    # virtual dispatch Widget#to_layout_html / the DOM loader actually use, an
    # inherited branch-root method runs with @type pinned to the branch root --
    # so a deeper subclass's own options (e.g. SpinBox#editable,
    # ScrollBar#tracking) were silently never (de)serialized. Defining the method
    # on each concrete subclass gives it its own specialization, the way
    # JSON::Serializable does. super still keeps @type at the concrete type, so
    # each level re-scans the same option set into the shared hash (idempotent),
    # bottoming out at the hand-written Widget base handler.
    {% if !t.abstract? &&
            !t.methods.any? { |m| m.name == "dom_attributes" || m.name == "dom_apply" } %}
      class ::{{ t }}
        def dom_attributes : ::Hash(::String, ::String?)
          attrs = super
          {% verbatim do %}
            dom_autoserialize_body :attributes
          {% end %}
          attrs
        end

        def dom_apply(key : ::String, value : ::String?) : ::Bool
          {% verbatim do %}
            dom_autoserialize_body :apply
          {% end %}
          true
        end
      end
    {% end %}
  {% end %}
end
