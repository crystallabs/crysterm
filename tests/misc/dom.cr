# FEATURE: HTML layout DOM.
#
# A Crysterm UI is a DOM: it can be BUILT from an HTML string (each `w-<tag>`
# element becomes the matching widget, attributes replay through real
# setters), STYLED with CSS stylesheets, and QUERIED live with full CSS
# selectors (`#id`, `.class`, types, `:nth-child`, ...) via
# `Window#resolve_selector`.
#
# This whole dashboard is one inline HTML string; a timer then updates it
# purely through selector queries. The same DOM is scriptable from OUTSIDE
# the process — over HTTP/JSON-RPC + SSE — when built with `-Dremote`.

require "../../src/crysterm"

include Crysterm

s = Window.new title: "Layout DOM"

s.load_layout <<-HTML
  <w-window>
    <style>
      .strip   { background: #202830; color: white; }
      .panel   { border: solid; background: #10141c; color: #c0caf5; }
      .row     { background: #10141c; color: #abb2bf; }
      .up      { color: #98c379; }
      .warn    { color: #e5c07b; }
      #status  { background: #182030; color: #61afef; }
      ProgressBar { border: solid; color: #c0caf5; background: #10141c; }
      ProgressBar::indicator { background: #2a6bd8; color: #c0caf5; }
    </style>

    <w-box class="strip" top="0" left="0" width="100%" height="1" parse-tags="true"
           content="{center}HTML layout DOM — this dashboard was built from an inline HTML string{/center}"></w-box>

    <w-box id="services" class="panel" top="2" left="2" width="36" height="15" label=" Services ">
      <w-box class="row" top="1" left="2" width="30" height="1" parse-tags="true"
             content="Web        {#98c379-fg}● up{/}"></w-box>
      <w-box class="row" top="3" left="2" width="30" height="1" parse-tags="true"
             content="Database   {#98c379-fg}● up{/}"></w-box>
      <w-box class="row" top="5" left="2" width="30" height="1" parse-tags="true"
             content="Cache      {#e5c07b-fg}● warm{/}"></w-box>
      <w-box class="row" top="7" left="2" width="30" height="1" parse-tags="true"
             content="Queue      {#98c379-fg}● up{/}"></w-box>
      <w-box id="ticker" class="row" top="10" left="2" width="30" height="3" parse-tags="true"
             content="Ticks: 0"></w-box>
    </w-box>

    <w-box class="panel" top="2" left="42" width="36" height="15" label=" Metrics ">
      <w-box class="row" top="1" left="2" width="30" height="1" content="CPU"></w-box>
      <w-progressbar id="cpu" top="2" left="2" width="31" height="3" value="35" text-visible="true"></w-progressbar>
      <w-box class="row" top="6" left="2" width="30" height="1" content="Memory"></w-box>
      <w-progressbar id="mem" top="7" left="2" width="31" height="3" value="55" text-visible="true"></w-progressbar>
      <w-box id="readout" class="row" top="11" left="2" width="31" height="2" parse-tags="true"
             content="CPU {bold}35%{/bold}  ·  Mem {bold}55%{/bold}"></w-box>
    </w-box>

    <w-box id="status" top="18" left="2" width="76" height="1" parse-tags="true"
           content=" Status: nominal   (resolve_selector(&quot;#status&quot;) rewrites this line)"></w-box>

    <w-box class="strip" top="20" left="0" width="100%" height="4" parse-tags="true"
           content="{center}Updated live via CSS queries: s.resolve_selector(&quot;#status&quot;), &quot;.row&quot;, ...{/center}
  {center}Build with -Dremote and the same DOM is scriptable over HTTP/JSON-RPC + SSE:{/center}
  {center}curl localhost:8933/dom?selector=%23status  ·  set-content, click, subscribe...{/center}"></w-box>
  </w-window>
  HTML

# --- from here on, the UI is only touched through CSS selector queries ------

PHASES = ["nominal", "syncing shards", "compacting", "rebalancing"]

tick = 0
s.every(0.25.seconds) do
  cpu = ((Math.sin(tick / 6.0) * 0.5 + 0.5) * 100).to_i
  mem = ((Math.cos(tick / 9.0) * 0.35 + 0.55) * 100).to_i

  s.resolve_selector("#cpu").each { |w| w.as(Widget::ProgressBar).value = cpu }
  s.resolve_selector("#mem").each { |w| w.as(Widget::ProgressBar).value = mem }
  s.resolve_selector("#readout").each do |w|
    w.content = "CPU {bold}#{cpu}%{/bold}  ·  Mem {bold}#{mem}%{/bold}"
  end
  s.resolve_selector("#ticker").each { |w| w.content = "Ticks: #{tick}" }
  s.resolve_selector("#status").each do |w|
    w.content = " Status: #{PHASES[(tick // 8) % PHASES.size]}   (resolve_selector(\"#status\") rewrites this line)"
  end
  tick += 1
end

s.exec
