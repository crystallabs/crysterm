var blessed = require('../../blessed')
  , screen;

s = blessed.screen({});

w = blessed.box({
  parent: s,
  top: 0,
	left: 0,
  shrink: true,
  content: 'Hello, World!',
  tags: false,
  style: {
    fg: 'yellow',
    bg: 'blue',
  },
  border: 'line',
});

s.on('keypress', function() {
  return s.destroy();
});

s.on('render', function() {
  scr = w.screenshot();
  console.error(scr);
  if(true) {
    process.exit()
  }
});

s.render();
