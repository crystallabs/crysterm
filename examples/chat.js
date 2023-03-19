// This is a chat example app for Blessed. Put into Blessed's example/ dir and run with:
// node example/chat.js

var blessed = require('../');

// Create a screen object.
var screen = blessed.screen({ dockBorders: true, ignoreDockContrast: true });

var style1 = { "fg": "black", "bg": "#729fcf" };
var style2 = { "fg": "black", "bg": "magenta", transparent: true };
var style3 = { "fg": "red", "bg": "green", "bar": { fg: "gray", bg: "yellow" } };

var sidebar = 40;

// Create a box perfectly centered horizontally and vertically.
var chat = blessed.textarea({
    top: 0,
    left: 0,
    width: "100%",
    height: "100%-3",
    value: "Chat session ...",
    parse_tags: false,
    border: { "type": "line", "fg": "black", "bg": "#729fcf" },
    style: style1
});

var  input = blessed.textbox({
    top: "100%-4",
    left: 0,
    width: "100%-39", // - sidebar
    height: 3,
    border: { "type": "line", "fg": "black", "bg": "#729fcf" },
    style: style1
});

var  members = blessed.list({
    top: 0,
    left: "100%-40",
    width: 40,
    height: "100%-3",
    border: { "type": "line", "fg": "black", "bg": "#729fcf" },
    scrollbar: true,
    transparent: true,
    style: style2,
    parse_tags: true,
    items: [ 'member1', 'member2', 'member3' ],
});

var lag = blessed.progressbar({
    top: "100%-4",
    left: "100%-40",
    width: 40,
    height: 3,
    border: { "type": "line", "fg": "black", "bg": "#729fcf" },
    content: "",
    parseTags: true,
    filled: 10,
    style: style3
});

screen.append(chat);
screen.append(members);
screen.append(input);
screen.append(lag);

// Quit on Escape, q, or Control-C.
screen.key(['escape', 'q', 'C-c'], function(ch, key) {
  return process.exit(0);
});

// Focus our element.
chat.focus();

// Render the screen.
screen.render();
