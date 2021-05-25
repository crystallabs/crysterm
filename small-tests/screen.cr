require "../src/crysterm"

include Crysterm

a = App.new

s = Widget::Screen.new #app: a

i = Widget::TextArea.new width: 40, height: 20, top: 20, left: 20 #"center", left: "center" #, border: true #, screen: s
#s.append i

#STDERR.puts i.focused?

#a.exec
