# Shared media/graph bitmap builders, hoisted out of the ~14 spec files that
# each defined their own `blank_bitmap`/`solid_bitmap`/`red_bitmap` (all
# `Array.new(h) { Array.new(w) { PNGGIF::Pixel.new(r, g, b, a) } }` under
# slightly different names/signatures). `PNGGIF::Pixel` is a struct (value
# type), so switching `red_bitmap`'s row-sharing construction to this
# per-cell builder changes nothing observable.

def bitmap(w, h, r = 0, g = 0, b = 0, a = 255) : PNGGIF::Bitmap
  Array.new(h) { Array.new(w) { PNGGIF::Pixel.new(r, g, b, a) } }
end

# a: 0 => fully transparent/blank.
def blank_bitmap(w, h) : PNGGIF::Bitmap
  bitmap(w, h, a: 0)
end

def solid_bitmap(w = 4, h = 4, r = 10, g = 20, b = 30) : PNGGIF::Bitmap
  bitmap(w, h, r, g, b)
end

def red_bitmap(w = 8, h = 8) : PNGGIF::Bitmap
  bitmap(w, h, 255, 0, 0, 255)
end
