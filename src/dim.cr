module Crysterm
  # A typed geometry value for `Widget` position/size properties (`left`,
  # `top`, `right`, `bottom`, `width`, `height`) — the parsed form of the
  # stringly micro-DSL (`"50%"`, `"50%+5"`, `"center-3"`, `"half"`, `"50vw"`).
  #
  # Values are parsed **once, at assignment** (`Dim.from` in the setters), so
  # a malformed expression raises `ArgumentError` right where it is written
  # instead of silently resolving to 0 every frame, and the per-frame
  # resolvers (`awidth`/`aleft`/...) do no string scanning at all.
  #
  # Construct directly for a fully typed API:
  #
  # ```
  # Widget::Box.new left: Dim.center, width: Dim.percent(50, -2)
  # Widget::Box.new left: :center, width: "50%-2" # same, via the compat forms
  # ```
  #
  # A plain `Int32` remains the spelling for a fixed cell count and is stored
  # unwrapped; `Dim.cells` exists for code that wants to be explicit.
  struct Dim
    # What the value means; `Auto` (stretch/unanchored) is spelled `nil` at
    # the property level, not as a `Dim`.
    enum Kind : UInt8
      # A fixed cell count.
      Cells
      # A percentage of the parent's content extent, plus/minus a cell offset.
      Percent
      # Centered in the parent (50% of the extent; a *position* additionally
      # pulls back by half this widget's own size), plus/minus a cell offset.
      Center
      # A percentage of a window edge (CSS `vw`/`vh`/`vmin`/`vmax`), resolved
      # against the live window size every frame.
      Viewport
    end

    # Which window edge a `Viewport` value resolves against.
    enum ViewportAxis : UInt8
      Width  # vw
      Height # vh
      Min    # vmin — the smaller window side
      Max    # vmax — the larger window side
    end

    getter kind : Kind

    # `Cells`: the cell count. Every other kind: the `±N` cell offset.
    getter offset : Int32

    # `Percent`/`Viewport`: the percentage as written (`33.5` for `"33.5%"`);
    # `Center`: 50.0; `Cells`: 0.0.
    getter percent : Float64

    # `Viewport` only: the window edge the percentage resolves against.
    getter viewport_axis : ViewportAxis

    protected def initialize(@kind, @offset = 0, @percent = 0.0, @viewport_axis = ViewportAxis::Width)
    end

    # A fixed cell count.
    def self.cells(n : Int32) : Dim
      new Kind::Cells, n
    end

    # *pct* percent of the parent's content extent, plus *offset* cells
    # (negative to subtract): `Dim.percent(50, -2)` ↔ `"50%-2"`.
    def self.percent(pct : Number, offset : Int32 = 0) : Dim
      new Kind::Percent, offset, pct.to_f64
    end

    # Centered in the parent, plus *offset* cells: `Dim.center(5)` ↔
    # `"center+5"`. As a position it pulls back by half the widget's own size;
    # as a size it is plain 50%.
    def self.center(offset : Int32 = 0) : Dim
      new Kind::Center, offset, 50.0
    end

    # *pct* percent of the window's width ↔ `"50vw"`.
    def self.vw(pct : Number) : Dim
      new Kind::Viewport, 0, pct.to_f64, ViewportAxis::Width
    end

    # *pct* percent of the window's height ↔ `"50vh"`.
    def self.vh(pct : Number) : Dim
      new Kind::Viewport, 0, pct.to_f64, ViewportAxis::Height
    end

    # *pct* percent of the window's smaller side ↔ `"50vmin"`.
    def self.vmin(pct : Number) : Dim
      new Kind::Viewport, 0, pct.to_f64, ViewportAxis::Min
    end

    # *pct* percent of the window's larger side ↔ `"50vmax"`.
    def self.vmax(pct : Number) : Dim
      new Kind::Viewport, 0, pct.to_f64, ViewportAxis::Max
    end

    def cells? : Bool
      @kind.cells?
    end

    def percent? : Bool
      @kind.percent?
    end

    def center? : Bool
      @kind.center?
    end

    def viewport? : Bool
      @kind.viewport?
    end

    # Matches `CSS::Length::VIEWPORT` (`50vw`, `.5VMIN`, ...).
    private VIEWPORT_RE = /\A(-?(?:\d+(?:\.\d+)?|\.\d+))(vw|vh|vmin|vmax)\z/i

    # Normalizes any accepted property spelling to its stored form: a `Dim`
    # or `Int32` passes through, `nil` stays `nil` (auto), a `String` is
    # parsed (raising `ArgumentError` when malformed — assignment is the
    # right place to learn about a typo, not a 0-resolved frame), and a
    # `Symbol` maps `:center` (and, for sizes, `:half`). *size* selects the
    # size-context alias (`"half"`) over the position one (`"center"`).
    def self.from(value : Dim | Int32 | String | Symbol?, size : Bool = false) : Dim | Int32?
      case value
      in Int32, Nil then value
      in Dim
        # A fixed cell count is canonically stored as a bare `Int32`, so
        # `w.width == 5` and `5 == w.width` both hold however it was spelled.
        value.cells? ? value.offset : value
      in String then parse value, size: size
      in Symbol
        case value
        when :center then center
        when :half
          raise ArgumentError.new "Dim :half is a size (use it for width/height; :center positions)" unless size
          percent 50
        else
          raise ArgumentError.new "Unknown Dim symbol: #{value.inspect} (expected :center or :half)"
        end
      end
    end

    # Parses a geometry expression: `"12"`, `"50%"`, `"50%+5"`, `"33.5%-2"`,
    # `"center"`/`"center+5"` (positions; `"half"` for sizes when *size*),
    # `"50vw"`/`"50vh"`/`"50vmin"`/`"50vmax"`. Raises `ArgumentError` on
    # anything else.
    def self.parse(str : String, size : Bool = false) : Dim
      parse?(str, size: size) ||
        raise ArgumentError.new "Invalid dimension expression: #{str.inspect} (expected N, N%±M, #{size ? "half" : "center"}±M, or Nvw/vh/vmin/vmax)"
    end

    # Like `.parse`, but returns `nil` on a malformed expression. The
    # render-path fallback for a raw `String` written directly into an ivar —
    # a frame must degrade (to the historical 0), never raise.
    def self.parse?(str : String, size : Bool = false) : Dim?
      # A bare integer is a cell count (CSS geometry usually converts these
      # before assignment; accept the spelling here too).
      if n = str.to_i?
        return cells n
      end

      # Viewport units. The `'v'` scan keeps the regex off non-viewport
      # values; parsing happens once, at assignment, unlike the historical
      # per-frame resolve.
      if (str.includes?('v') || str.includes?('V')) && (m = str.strip.match(VIEWPORT_RE))
        pct = m[1].to_f? || return
        axis = case m[2].downcase
               when "vw"   then ViewportAxis::Width
               when "vh"   then ViewportAxis::Height
               when "vmin" then ViewportAxis::Min
               else             ViewportAxis::Max
               end
        return new Kind::Viewport, 0, pct, axis
      end

      # The context-sensitive 50% alias: `"center"` for positions, `"half"`
      # for sizes, optionally with a `±N` cell offset.
      aliased = size ? "half" : "center"
      if str == aliased
        return center_like size
      elsif str.starts_with?(aliased) && (c = str[aliased.size]?) && (c == '+' || c == '-')
        off = parse_offset(str, aliased.size + 1) || return
        return center_like size, (c == '-' ? -off : off)
      end

      # Percentage with optional `±N` offset: `[+-]digits[.digits]% [+-]digits`.
      sep = -1
      i = 1
      while i < str.bytesize
        b = str.to_slice.unsafe_fetch(i)
        if b == '+'.ord || b == '-'.ord
          sep = i
          break
        end
        i += 1
      end
      pct_end = sep == -1 ? str.bytesize - 1 : sep - 1 # index of the '%'
      return unless pct_end > 0 && str.to_slice.unsafe_fetch(pct_end) == '%'.ord

      pct = parse_percent_number(str, pct_end) || return
      off = 0
      if sep != -1
        off = parse_offset(str, sep + 1) || return
        off = -off if str.to_slice.unsafe_fetch(sep) == '-'.ord
      end
      percent pct, off
    end

    # Parses the percentage number (`str[0, pct_end]`). `to_f?` returns nil
    # for out-of-range (ERANGE) numbers that are nevertheless *well-formed* —
    # e.g. a 320-digit percentage (B17-05). Historically those saturated and
    # rendered (the `resolve` clamp bounds them), and only genuinely
    # malformed input raises at assignment — so re-scan the form here and
    # saturate to ±INFINITY instead of rejecting.
    private def self.parse_percent_number(str : String, pct_end : Int32) : Float64?
      s = str[0, pct_end]
      if v = s.to_f?
        return v
      end
      bytes = s.to_slice
      return if bytes.empty?
      i = 0
      neg = false
      b0 = bytes.unsafe_fetch(0)
      if b0 == '-'.ord
        neg = true
        i = 1
      elsif b0 == '+'.ord
        i = 1
      end
      dot = false
      digits = false
      while i < bytes.size
        b = bytes.unsafe_fetch(i)
        if b == '.'.ord && !dot
          dot = true
        elsif '0'.ord <= b <= '9'.ord
          digits = true
        else
          return
        end
        i += 1
      end
      return unless digits
      neg ? -Float64::INFINITY : Float64::INFINITY
    end

    # `"center"`/`"half"` both mean 50%, but only a *position* center pulls
    # back by half the widget's own size — a size stays a plain percentage.
    private def self.center_like(size : Bool, offset : Int32 = 0) : Dim
      size ? percent(50, offset) : center(offset)
    end

    # Parses the digits-only cell offset starting at byte *from*; `nil` when
    # empty or non-digit (the historical parsers treated those as malformed).
    private def self.parse_offset(str : String, from : Int32) : Int32?
      bytes = str.to_slice
      return if from >= bytes.size
      off = 0
      j = from
      while j < bytes.size
        b = bytes.unsafe_fetch(j)
        return unless '0'.ord <= b <= '9'.ord
        # Clamp the accumulator so a pathological (≥10-digit) offset can't
        # overflow Int32 (mirrors the historical resolver).
        off = off < 100_000_000 ? off * 10 + (b.to_i - '0'.ord) : off
        j += 1
      end
      off
    end

    # Resolves against the parent's content extent *against*, in cells.
    # Byte-for-byte the same arithmetic as the historical per-frame String
    # resolution, so rendered output is unchanged. `Viewport` values need the
    # window size — use `#resolve_viewport`.
    def resolve(against : Int32) : Int32
      case @kind
      in .cells?
        @offset
      in .percent?, .center?
        # Clamp the product before the checked narrowing (B17-05, ported from
        # the deleted `Widget.resolve_percentage`): a pathologically large
        # percentage — or one long enough to saturate the parsed Float64 to
        # infinity — must not overflow Int32 on `.to_i` and raise in the
        # render path. The offset accumulator already saturates at parse time,
        # so the sum stays within Int32.
        v = against * (@percent / 100.0)
        v = -1_000_000_000.0 if v < -1_000_000_000.0
        v = 1_000_000_000.0 if v > 1_000_000_000.0
        v.to_i + @offset
      in .viewport?
        raise ArgumentError.new "A viewport Dim resolves against the window — use #resolve_viewport"
      end
    end

    # Resolves a `Viewport` value against the live window size (mirrors
    # `CSS::Length.viewport_cells`, rounding and clamping identically).
    def resolve_viewport(window_width : Int32, window_height : Int32) : Int32
      basis = case @viewport_axis
              in .width?  then window_width
              in .height? then window_height
              in .min?    then Math.min(window_width, window_height)
              in .max?    then Math.max(window_width, window_height)
              end
      (basis * @percent / 100.0).round.clamp(Int32::MIN.to_f64, Int32::MAX.to_f64).to_i
    end

    # A `Dim` equals the `Int32`/`String`/`Symbol` spelling it was parsed
    # from, so `w.width.should eq "50%"`-style comparisons keep working after
    # the parse-at-assignment normalization.
    def ==(other : Int32) : Bool
      cells? && @offset == other
    end

    # :ditto:
    def ==(other : String) : Bool
      self == Dim.parse?(other, size: false) || self == Dim.parse?(other, size: true)
    end

    # :ditto:
    def ==(other : Symbol) : Bool
      case other
      when :center then center? && @offset == 0
      when :half   then percent? && @percent == 50.0 && @offset == 0
      else              false
      end
    end

    # Emits the canonical source spelling (`"50%+5"`, `"center-3"`, `"7"`,
    # `"50vw"`), so DOM/HTML serialization round-trips through `Dim.parse`.
    def to_s(io : IO) : Nil
      case @kind
      in .cells?
        io << @offset
      in .percent?
        emit_number io, @percent
        io << '%'
        emit_offset io
      in .center?
        io << "center"
        emit_offset io
      in .viewport?
        emit_number io, @percent
        io << case @viewport_axis
        in .width?  then "vw"
        in .height? then "vh"
        in .min?    then "vmin"
        in .max?    then "vmax"
        end
      end
    end

    def inspect(io : IO) : Nil
      io << "Dim(" << self << ')'
    end

    private def emit_number(io : IO, n : Float64) : Nil
      if n == n.floor && Int32::MIN <= n <= Int32::MAX
        io << n.to_i
      else
        io << n
      end
    end

    private def emit_offset(io : IO) : Nil
      if @offset > 0
        io << '+' << @offset
      elsif @offset < 0
        io << @offset
      end
    end
  end
end
