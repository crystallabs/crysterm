require "../src/crysterm"

# Focused allocation probe (pass 2), ARTIFACT-FREE.
# Earlier version was contaminated: draw(flush:true) writes into an IO::Memory
# output that accumulates forever (never cleared without a real tty), and
# insert_line diverts into @_buf which only `draw` clears — both produce
# amortized IO::Memory-doubling that masqueraded as per-op allocation. Here we
# measure draw(flush:false) (pure diff/encode into REUSED @main/@outbuf) and,
# for the flush path, clear the output each frame. Ground truth = these.

include Crysterm

W = 200
H =  50

ATTR_A = Attr.pack(0_i64, Attr.pack_color(0xFF5050), Attr.pack_color(0x101010))
ATTR_B = Attr.pack(0_i64, Attr.pack_color(0x50A0FF), Attr.pack_color(0x101010))

def bytes(n, &block : Int32 -> _) : Float64
  GC.collect
  before = GC.stats.total_bytes
  n.times { |i| block.call i }
  (GC.stats.total_bytes - before) / n.to_f
end

def mkscreen(outp = IO::Memory.new(1 << 22)) : Window
  s = Window.new input: IO::Memory.new, output: outp, error: IO::Memory.new,
    width: W, height: H
  s.width = W
  s.height = H
  s.realloc
  s.draw flush: false
  s
end

s = mkscreen
puts "=" * 60
puts "Draw/render allocation probe (artifact-free)  bytes/op"
puts "colors=#{s.colors}  ansi_cursor=#{s.draw_caps.ansi_cursor}"
puts "=" * 60

# 1. draw(flush:false) 1-cell color toggle — pure diff/encode, reused buffers.
one = bytes(50_000) do |i|
  cell = s.lines[H // 2][W // 2]
  cell.attr = i.even? ? ATTR_A : ATTR_B
  cell.char = i.even? ? 'A' : 'B'
  s.lines[H // 2].mark_dirty(W // 2)
  s.draw flush: false
end
puts "1  draw(flush:false) 1-cell color  #{one.round(3)} B/frame"

# 1x. draw(flush:false) on an UNCHANGED frame (no output produced) — isolates
# whether the ~48 B is the "output produced" @pre/@post cursor block.
s1x = mkscreen
unchg = bytes(50_000) { |i| s1x.draw flush: false }
puts "1x draw(flush:false) UNCHANGED ... #{unchg.round(3)} B/frame"

# 1y. direct cost of the four cursor terminfo capabilities the output block emits.
tpx = s.tput
sc = bytes(50_000) { |i| tpx.save_cursor }
rc = bytes(50_000) { |i| tpx.restore_cursor }
hc = bytes(50_000) { |i| tpx.hide_cursor }
sh = bytes(50_000) { |i| tpx.show_cursor }
chd = bytes(50_000) { |i| tpx.cursor_hidden? }
puts "1y save_cursor=#{sc.round(1)} restore=#{rc.round(1)} hide=#{hc.round(1)} show=#{sh.round(1)} hidden?=#{chd.round(1)} B/op"

# 2. draw(flush:false) full-screen change every frame (heavy encode).
full = bytes(5_000) do |i|
  a = i.even? ? ATTR_A : ATTR_B
  ch = i.even? ? 'A' : 'B'
  H.times do |y|
    line = s.lines[y]
    W.times { |x| c = line[x]; c.attr = a; c.char = ch }
    line.dirty = true
  end
  s.draw flush: false
end
puts "2  draw(flush:false) full-screen . #{full.round(3)} B/frame (#{(full/(W*H)).round(4)} B/cell)"

# 3. flush_frame alone, output cleared each frame (isolates the write path).
outbuf = IO::Memory.new(1 << 20)
s3 = mkscreen(outbuf)
fl = bytes(50_000) do |i|
  outbuf.clear
  s3.lines[0][i % W].attr = i.even? ? ATTR_A : ATTR_B
  s3.lines[0].mark_dirty(i % W)
  s3.draw # flush:true -> flush_frame, output cleared above
end
puts "3  draw+flush 1-cell (out cleared) #{fl.round(3)} B/frame"

# 4. scroll: insert_line / delete_line, folding @_buf via draw each iter.
s4 = mkscreen
ins = bytes(20_000) do |i|
  s4.insert_line 1, 0, 0, H - 1
  s4.draw flush: false # folds @_buf into @main (clears @_buf)
end
puts "4a insert_line + draw ............ #{ins.round(2)} B/op"
del = bytes(20_000) do |i|
  s4.delete_line 1, 0, 0, H - 1
  s4.draw flush: false
end
puts "4b delete_line + draw ............ #{del.round(2)} B/op"
# 4c/d isolate the tput terminfo.run cost for il/dl (the real per-op alloc).
tp = s4.tput
il = bytes(50_000) { |i| tp.il 1 }
puts "4c tput.il(1) (terminfo.run) ..... #{il.round(2)} B/op"
dl = bytes(50_000) { |i| tp.dl 1 }
puts "4d tput.dl(1) (terminfo.run) ..... #{dl.round(2)} B/op"
csr = bytes(50_000) { |i| tp.set_scroll_region 0, H - 1 }
puts "4e tput.set_scroll_region (ANSI) . #{csr.round(2)} B/op"
cup = bytes(50_000) { |i| tp.cup 5, 5 }
puts "4f tput.cup (ANSI) ............... #{cup.round(2)} B/op"

# 5. clear_region / invalidate_region / blend (already-known clean).
s5 = mkscreen
clr = bytes(50_000) { |i| s5.lines[i % H][i % W].char = 'z'; s5.clear_region 0, W, 0, H }
puts "5a clear_region full ............. #{clr.round(3)} B/op"
inv = bytes(50_000) { |i| s5.invalidate_region 0, W, 0, H }
puts "5b invalidate_region full ........ #{inv.round(3)} B/op"

# 6. dump() (capture text path) per call — on-demand, not per-frame.
s6 = mkscreen
dp = bytes(2_000) { |i| s6.dump }
puts "6  dump() full screen ............ #{dp.round(0)} B/call"
