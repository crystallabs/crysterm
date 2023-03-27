require "benchmark"

require "../src/crysterm"

# This tests performance of accessing a 2D grid that represents cells on the
# screen. The original implementation from Blessed has cells represented as
# chars to which it attaches an additional property 'attr'.
#
# In Crysterm this was ported over as `class Cell`. In search of ways to
# optimize that, this test file was created.
#
# Results were:
#                                             user     system      total        real
# class Cell                               3.221470   0.001085   3.222555 (  3.251506)
# struct Cell                              2.960962   0.000000   2.960962 (  2.993685)
# separate arrays, combined access yx      1.208852   0.000000   1.208852 (  1.221377)
# separate arrays, separate access yx      1.678196   0.000001   1.678197 (  1.693666)
# separate arrays, combined access xy      2.278242   0.000000   2.278242 (  2.301951)
# separate arrays, separate access xy      2.512557   0.000000   2.512557 (  2.550904)
# separate 1d arrays, combined access yx   1.821288   0.000000   1.821288 (  1.850375)
# separate 1d arrays, combined access xy   1.771367   0.000000   1.771367 (  1.808968)
#
# Which shows that the optimal way is to split the whole thing into 2 separate 2D
# arrays (for attrs and cells) and to access them in [y][x] fashion, e.g:
#
# (ystart...yend) do |y|
#   (xstart...xend) do |x|
#      attrs[y][x] = val
#      chars[y][x] = val
#   end
# end
#
# But not done for now since this is not where the most of time is being spent, and
# changing this part requires a lot of changes. See patches/2-separate-arrays.patch
# as a good base to finish the work.

xs = 2000
ys = 600
reps = 1000000

module Crysterm
  # Equivalent of Cell, but done as a struct
  struct Cell2
    include Comparable(self)
    getter attr : Int32 = ((0 << 18) | (0x1ff << 9)) | 0x1ff
    getter char : Char = ' '

    def attr=(@attr)
      self
    end

    def char=(@char)
      self
    end

    def initialize(@attr, @char)
    end

    def initialize(@char)
    end

    def initialize
    end

    def <=>(other : Cell)
      if (d = @attr <=> other.attr) == 0
        @char <=> other.char
      else
        d
      end
    end

    def <=>(other : Tuple(Int32, Char))
      if (d = @attr <=> other[0]) == 0
        @char <=> other[1]
      else
        d
      end
    end
  end

  # Individual screen row
  class Row2 < Array(Cell2)
    property dirty = false

    def initialize
      super
    end

    def initialize(width, cell : Cell2 | Tuple(Int32, Char) = {@attr, @char})
      super width
    end
  end

  puts :running

  # Set up cells (classes)
  lines = Array(Screen::Row).new
  ys.times do
    row = Screen::Row.new
    xs.times do
      row.push Screen::Cell.new 0, 'x'
    end
    lines.push row
  end

  # Set up cells (structs)
  lines2 = Array(Row2).new
  ys.times do
    row = Row2.new
    xs.times do
      row.push Cell2.new 0, 'x'
    end
    lines2.push row
  end

  # Set up cells as 2 separate things
  lines3_attr = Array(Array(Int32)).new
  lines3_char = Array(Array(Char)).new
  ys.times do
    row_attr = Array(Int32).new
    row_char = Array(Char).new

    xs.times do
      row_attr.push 0
      row_char.push 'x'
    end
    lines3_attr.push row_attr
    lines3_char.push row_char
  end

  # Set up cells as 2 separate things
  lines4_attr = Array(Int32).new
  lines4_char = Array(Char).new
  (ys * xs).times do
    lines4_attr.push 0
    lines4_char.push 'x'
  end

  Benchmark.bm do |x|
    x.report "class Cell" do
      reps.times do
        xsize = 20 # Random.rand xs-1
        xpos = Random.rand xs - 1 - xsize
        ysize = 20 # Random.rand ys-1
        ypos = Random.rand ys - 1 - ysize

        # Iterate over the cells of the screen, setting them to something
        (ypos...ypos + ysize).each do |y|
          (xpos...xpos + xsize).each do |x|
            lines[y][x].attr = 10
            lines[y][x].char = 'e'
          end
        end
      end
    end

    x.report "struct Cell" do
      reps.times do
        xsize = 20 # Random.rand xs-1
        xpos = Random.rand xs - 1 - xsize
        ysize = 20 # Random.rand ys-1
        ypos = Random.rand ys - 1 - ysize

        # Iterate over the cells of the screen, setting them to something
        (ypos...ypos + ysize).each do |y|
          (xpos...xpos + xsize).each do |x|
            lines2[y][x] = lines2[y][x].attr = 10
            lines2[y][x] = lines2[y][x].char = 'e'
          end
        end
      end
    end

    x.report "separate arrays, combined access yx" do
      reps.times do
        xsize = 20 # Random.rand xs-1
        xpos = Random.rand xs - 1 - xsize
        ysize = 20 # Random.rand ys-1
        ypos = Random.rand ys - 1 - ysize

        # Iterate over the cells of the screen, setting them to something
        (ypos...ypos + ysize).each do |y|
          (xpos...xpos + xsize).each do |x|
            lines3_attr[y][x] = 0
            lines3_char[y][x] = 'e'
          end
        end
      end
    end

    x.report "separate arrays, separate access yx" do
      reps.times do
        xsize = 20 # Random.rand xs-1
        xpos = Random.rand xs - 1 - xsize
        ysize = 20 # Random.rand ys-1
        ypos = Random.rand ys - 1 - ysize

        # Iterate over the cells of the screen, setting them to something
        (ypos...ypos + ysize).each do |y|
          (xpos...xpos + xsize).each do |x|
            lines3_attr[y][x] = 0
          end
        end

        # Iterate over the cells of the screen, setting them to something
        (ypos...ypos + ysize).each do |y|
          (xpos...xpos + xsize).each do |x|
            lines3_char[y][x] = 'e'
          end
        end
      end
    end

    x.report "separate arrays, combined access xy" do
      reps.times do
        xsize = 20 # Random.rand xs-1
        xpos = Random.rand xs - 1 - xsize
        ysize = 20 # Random.rand ys-1
        ypos = Random.rand ys - 1 - ysize

        # Iterate over the cells of the screen, setting them to something
        (xpos...xpos + xsize).each do |x|
          (ypos...ypos + ysize).each do |y|
            lines3_attr[y][x] = 0
            lines3_char[y][x] = 'e'
          end
        end
      end
    end

    x.report "separate arrays, separate access xy" do
      reps.times do
        xsize = 20 # Random.rand xs-1
        xpos = Random.rand xs - 1 - xsize
        ysize = 20 # Random.rand ys-1
        ypos = Random.rand ys - 1 - ysize

        # Iterate over the cells of the screen, setting them to something
        (xpos...xpos + xsize).each do |x|
          (ypos...ypos + ysize).each do |y|
            lines3_attr[y][x] = 0
          end
        end

        # Iterate over the cells of the screen, setting them to something
        (xpos...xpos + xsize).each do |x|
          (ypos...ypos + ysize).each do |y|
            lines3_char[y][x] = 'e'
          end
        end
      end
    end

    x.report "separate 1d arrays, combined access yx" do
      reps.times do
        xsize = 20 # Random.rand xs-1
        xpos = Random.rand xs - 1 - xsize
        ysize = 20 # Random.rand ys-1
        ypos = Random.rand ys - 1 - ysize

        # Iterate over the cells of the screen, setting them to something
        (ypos...ypos + ysize).each do |y|
          (xpos...xpos + xsize).each do |x|
            lines4_attr[y*x + x] = 0
            lines4_char[y*x + x] = 'e'
          end
        end
      end
    end

    x.report "separate 1d arrays, combined access xy" do
      reps.times do
        xsize = 20 # Random.rand xs-1
        xpos = Random.rand xs - 1 - xsize
        ysize = 20 # Random.rand ys-1
        ypos = Random.rand ys - 1 - ysize

        # Iterate over the cells of the screen, setting them to something
        (xpos...xpos + xsize).each do |x|
          (ypos...ypos + ysize).each do |y|
            lines4_attr[y*x + x] = 0
            lines4_char[y*x + x] = 'e'
          end
        end
      end
    end
  end
end
