require "../src/crysterm"
include Crysterm

def fd_alive?(fd)
  LibC.fcntl(fd, LibC::F_GETFD, 0) != -1
end

path = ARGV[0]
s1 = Crysterm::Screen.new(title: "s1")
# FIX ATTEMPT: stop the dup'd std-stream wrappers from auto-closing their fd.
[s1.input, s1.output, s1.error].each do |io|
  io.close_on_finalize = false if io.is_a?(IO::FileDescriptor)
end
input = File.open(path, "r"); output = File.open(path, "w"); output.sync = true
s2 = Crysterm::Screen.new(title: "s2", input: input, output: output)

i, o = s1.input.as(IO::FileDescriptor).fd, s1.output.as(IO::FileDescriptor).fd
STDERR.puts "before GC: s1.in fd#{i}=#{fd_alive?(i)} s1.out fd#{o}=#{fd_alive?(o)}"
GC.collect; GC.collect
STDERR.puts "after  GC: s1.in fd#{i}=#{fd_alive?(i)} s1.out fd#{o}=#{fd_alive?(o)}"
