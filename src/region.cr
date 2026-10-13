require "./geometry"

module Crysterm
  # A set of cells made of disjoint rectangles — Qt's `QRegion`, on the cell
  # grid. The value `Widget#visible_region` answers: a widget's rectangle less
  # the rectangles painted above it, which a picture the terminal keeps apart
  # from its cells (a Kitty placement, an external helper's window) presents
  # piece by piece, so a menu or dialog stacked over it stays on top.
  #
  # Like `QRegion`, a region is a value: `#subtracted` and `#intersected` return
  # a new one and leave the receiver as it was. Its `#rects` are disjoint, and
  # for the same operations in the same order they come out the same, so two
  # regions built alike compare equal (`==`) and a caller can tell a changed
  # region from an unchanged one by comparing them.
  struct Region
    # The disjoint, non-empty rectangles the region is made of ↔
    # `QRegion::rects`. Do not mutate: regions share it.
    getter rects : Array(Rectangle)

    # The empty region.
    def initialize
      @rects = [] of Rectangle
    end

    # The region covering *rect* (empty for an empty rectangle) ↔
    # `QRegion(const QRect &)`.
    def initialize(rect : Rectangle)
      @rects = rect.empty? ? [] of Rectangle : [rect]
    end

    # The region made of *rects*, which the caller guarantees to be disjoint
    # and non-empty.
    protected def initialize(@rects : Array(Rectangle), *, disjoint : Bool)
    end

    # Whether the region covers no cell ↔ `QRegion::isEmpty`.
    def empty? : Bool
      @rects.empty?
    end

    # Number of cells the region covers.
    def area : Int32
      @rects.sum { |r| r.width * r.height }
    end

    # The smallest rectangle containing the region ↔ `QRegion::boundingRect`;
    # an empty rectangle for the empty region.
    def bounding_rect : Rectangle
      @rects.reduce(Rectangle.new(0, 0, 0, 0)) { |acc, r| acc | r }
    end

    # Whether the region covers the cell (*x*, *y*) ↔ `QRegion::contains`.
    def contains?(x : Int32, y : Int32) : Bool
      @rects.any?(&.contains?(x, y))
    end

    # This region less the cells of *rect* ↔ `QRegion::subtracted`. Each
    # rectangle *rect* cuts into is replaced by what is left of it: the full
    # width above and below the cut, and the parts beside it on its rows.
    def subtracted(rect : Rectangle) : Region
      return self if rect.empty? || @rects.none?(&.intersects?(rect))
      parts = [] of Rectangle
      @rects.each do |a|
        unless a.intersects?(rect)
          parts << a
          next
        end
        i = a & rect
        add_nonempty parts, Rectangle.of_edges(a.xi, a.yi, a.xl, i.yi)
        add_nonempty parts, Rectangle.of_edges(a.xi, i.yi, i.xi, i.yl)
        add_nonempty parts, Rectangle.of_edges(i.xl, i.yi, a.xl, i.yl)
        add_nonempty parts, Rectangle.of_edges(a.xi, i.yl, a.xl, a.yl)
      end
      Region.new parts, disjoint: true
    end

    # This region less every cell of *other* ↔ `QRegion::subtracted(QRegion)`.
    def subtracted(other : Region) : Region
      other.rects.reduce(self) { |acc, r| acc.subtracted r }
    end

    # The cells of this region inside *rect* ↔ `QRegion::intersected`.
    def intersected(rect : Rectangle) : Region
      parts = [] of Rectangle
      @rects.each { |a| add_nonempty parts, a & rect }
      Region.new parts, disjoint: true
    end

    # The region moved by *dx* columns and *dy* rows ↔ `QRegion::translated`.
    def translated(dx : Int32, dy : Int32) : Region
      Region.new @rects.map(&.translated(dx, dy)), disjoint: true
    end

    # Appends *r* to *acc* unless it covers no cell.
    private def add_nonempty(acc : Array(Rectangle), r : Rectangle) : Nil
      acc << r unless r.empty?
    end
  end
end
