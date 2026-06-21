require "../src/crysterm"
include Crysterm
# Two screens on two different terminals; report each one's detected size.
ina = File.open(ARGV[0], "r"); outa = File.open(ARGV[0], "w"); outa.sync = true
inb = File.open(ARGV[1], "r"); outb = File.open(ARGV[1], "w"); outb.sync = true
sa = Crysterm::Screen.new(title: "A", input: ina, output: outa)
sb = Crysterm::Screen.new(title: "B", input: inb, output: outb)
STDERR.puts "screen A (#{ARGV[0]}): #{sa.awidth}x#{sa.aheight}"
STDERR.puts "screen B (#{ARGV[1]}): #{sb.awidth}x#{sb.aheight}"
