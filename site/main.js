// The page draws Fremspace instead of describing it. Every moving part below is a drawing of
// something the app does: windows going to their slots, Focus, a stack, the drawers, the palette,
// the notch. The Mac, its windows and what is in them are drawn here; nothing talks to a server.
(function () {
  'use strict';

  var doc = document;
  doc.documentElement.classList.add('js');
  var still = !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);

  function $(id) { return doc.getElementById(id); }
  function el(tag, cls, html) {
    var node = doc.createElement(tag);
    if (cls) node.className = cls;
    if (html != null) node.innerHTML = html;
    return node;
  }
  function each(list, fn) { Array.prototype.forEach.call(list, fn); }
  function mix(a, b) { var o = {}, k; for (k in a) o[k] = a[k]; for (k in b) o[k] = b[k]; return o; }
  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)); }

  // Timers of one drawing, dropped together when it leaves the viewport or changes act.
  function Timeline() { this.ids = []; }
  Timeline.prototype.at = function (ms, fn) { this.ids.push(setTimeout(fn, ms)); };
  Timeline.prototype.clear = function () { this.ids.forEach(clearTimeout); this.ids = []; };

  // A drawing only runs while it is on screen: nothing animates behind the reader's back.
  function whenVisible(node, start, stop) {
    if (!('IntersectionObserver' in window)) { start(); return; }
    var on = false;
    new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting && !on) { on = true; start(); }
        else if (!entry.isIntersecting && on) { on = false; if (stop) stop(); }
      });
    }, { threshold: 0.12 }).observe(node);
  }

  // A scene is drawn at a fixed size in its own pixels and scaled to the width it is given, so a
  // window keeps its proportions from a phone to a wide display.
  function fit(box, w, h) {
    var inner = el('div', 'fit-in');
    box.appendChild(inner);
    var state = { scale: 1, w: w, h: h, inner: inner };
    function apply() {
      state.scale = box.clientWidth / state.w || 1;
      inner.style.transform = 'scale(' + state.scale + ')';
    }
    state.size = function (nw, nh) {
      state.w = nw; state.h = nh;
      box.style.aspectRatio = nw + ' / ' + nh;
      inner.style.width = nw + 'px';
      inner.style.height = nh + 'px';
      apply();
    };
    state.size(w, h);
    if ('ResizeObserver' in window) new ResizeObserver(apply).observe(box);
    else window.addEventListener('resize', apply);
    return state;
  }

  /* --- Springs ---------------------------------------------------------------------------------
     Windows are moved by springs, not by timed transitions: a window caught half way (a drag, a
     second key press) goes on from where it is, at the speed it has. */
  var KEYS = ['x', 'y', 'w', 'h', 'r', 's', 'o'];
  var EPS = { x: 0.15, y: 0.15, w: 0.15, h: 0.15, r: 0.03, s: 0.002, o: 0.004 };
  var moving = [], ticking = false, lastTick = 0;

  function Mover(node, init) {
    this.node = node;
    this.cur = mix({ x: 0, y: 0, w: 100, h: 100, r: 0, s: 1, o: 1 }, init || {});
    this.aim = mix(this.cur, {});
    this.vel = { x: 0, y: 0, w: 0, h: 0, r: 0, s: 0, o: 0 };
    this.k = 190; this.c = 21;
    this.rest = true; this.timer = 0; this.done = null;
    this.paint();
  }
  Mover.prototype.paint = function () {
    var c = this.cur, st = this.node.style;
    st.transform = 'translate3d(' + c.x.toFixed(2) + 'px,' + c.y.toFixed(2) + 'px,0) rotate(' + c.r.toFixed(2) + 'deg) scale(' + c.s.toFixed(3) + ')';
    // Size and opacity are only written when they change: a window that just travels stays on
    // the compositor.
    var w = c.w.toFixed(1), h = c.h.toFixed(1), o = clamp(c.o, 0, 1).toFixed(3);
    if (w !== this.pw) { st.width = w + 'px'; this.pw = w; }
    if (h !== this.ph) { st.height = h + 'px'; this.ph = h; }
    if (o !== this.po) { st.opacity = o; this.po = o; }
  };
  Mover.prototype.set = function (p) {
    clearTimeout(this.timer);
    for (var k in p) { this.cur[k] = this.aim[k] = p[k]; this.vel[k] = 0; }
    this.paint();
  };
  Mover.prototype.go = function (p, opt) {
    var self = this;
    clearTimeout(this.timer);
    if (still) { this.set(p); if (this.done) this.done(); return; }
    function start() {
      for (var k in p) self.aim[k] = p[k];
      self.k = (opt && opt.k) || 190;
      self.c = (opt && opt.c) || 21;
      if (self.rest) { self.rest = false; moving.push(self); }
      if (!ticking) { ticking = true; lastTick = 0; requestAnimationFrame(tick); }
    }
    if (opt && opt.delay) this.timer = setTimeout(start, opt.delay); else start();
  };
  Mover.prototype.step = function (dt) {
    var busy = false, k, d;
    for (var i = 0; i < KEYS.length; i++) {
      k = KEYS[i];
      d = this.aim[k] - this.cur[k];
      this.vel[k] += (this.k * d - this.c * this.vel[k]) * dt;
      this.cur[k] += this.vel[k] * dt;
      if (Math.abs(d) > EPS[k] || Math.abs(this.vel[k]) > EPS[k] * 4) busy = true;
    }
    if (!busy) {
      for (i = 0; i < KEYS.length; i++) { k = KEYS[i]; this.cur[k] = this.aim[k]; this.vel[k] = 0; }
      this.rest = true;
    }
  };
  function tick(now) {
    var dt = lastTick ? Math.min(0.034, (now - lastTick) / 1000) : 0.016;
    lastTick = now;
    var steps = Math.max(1, Math.round(dt / 0.006)), h = dt / steps, finished = [];
    for (var i = moving.length - 1; i >= 0; i--) {
      var m = moving[i];
      for (var s = 0; s < steps && !m.rest; s++) m.step(h);
      m.paint();
      if (m.rest) { moving.splice(i, 1); finished.push(m); }
    }
    finished.forEach(function (m) { if (m.done) m.done(); });
    if (moving.length) requestAnimationFrame(tick); else ticking = false;
  }

  /* --- What a window looks like ------------------------------------------------------------------
     Windows are drawn the way macOS draws them. What is in them is invented, and borrows its names
     from Dune, where a Guild Navigator folds space: a trade paper from Arrakeen, a list for the deep
     desert, a navigator's code. Names only: no line from the books, nobody's portrait. */
  var NAMES = { code: 'Code', safari: 'Safari', terminal: 'Terminal', mail: 'Mail', messages: 'Messages', calendar: 'Calendar', notes: 'Notes', music: 'Music' };
  var TITLES = { code: 'Fold.swift', terminal: 'navigator — zsh', mail: 'Inbox', messages: 'Messages', calendar: 'Calendar', notes: 'Notes', music: 'Music' };

  // The three pages a Safari window can show.
  var PAGES = [
    { title: 'Spice harvest up again', site: 'Arrakeen Dispatch', url: 'dispatch.arrakeen.example/spice-harvest', kicker: 'Trade', menu: ['Spice', 'Guild', 'Weather', 'Shipping'],
      text: ['Crews in the Imperial Basin report their best month of the year. The storms came late, and the harvesters stayed out on the sand for longer.',
        'The Guild has raised its rate for the Arrakeen run all the same.'] },
    { title: 'Along the Shield Wall', site: 'Sandwalker', url: 'sandwalker.example/shield-wall-on-foot', kicker: 'On foot', menu: ['Routes', 'Sietches', 'Water', 'Kit'],
      text: ['Start before dawn and keep to the rock. On the open sand, break your step: a steady walk carries a long way down.',
        'Carry more water than you think you need. Then wear the stillsuit anyway.'] },
    { title: 'Rain over Caladan', site: 'Caladan Courier', url: 'courier.caladan.example/harbour', kicker: 'Home waters', menu: ['Harbour', 'Fleet', 'Tides', 'Letters'],
      text: ['Three weeks of rain over the harbour, the fishing fleet is in, and nobody has complained yet.',
        'Visitors from drier worlds stand in it with their mouths open.'] }
  ];

  var SOURCE = [
    '<b class="k">struct</b> <b class="t">Route</b> {',
    '    <b class="k">var</b> from: <b class="t">Planet</b>',
    '    <b class="k">var</b> to: <b class="t">Planet</b>',
    '    <b class="k">var</b> cargo: [<b class="t">Frigate</b>] = []',
    '}',
    '',
    '<b class="c">// Fold space between two planets, if the spice allows.</b>',
    '<b class="k">func</b> <b class="f">fold</b>(<b class="k">_</b> route: <b class="t">Route</b>, with spice: <b class="t">Spice</b>) -&gt; <b class="t">Arrival</b>? {',
    '    <b class="k">guard</b> spice.grams &gt;= route.cost <b class="k">else</b> { <b class="k">return nil</b> }',
    '    <b class="k">let</b> path = <b class="t">Navigator</b>.<b class="f">see</b>(route)',
    '    <b class="k">return</b> <b class="t">Heighliner</b>.shared',
    '        .<b class="f">fold</b>(along: path)',
    '        .<b class="f">arrive</b>(at: route.to)',
    '}',
    '',
    '<b class="k">let</b> run = <b class="t">Route</b>(from: .caladan, to: .arrakis)',
    '<b class="f">print</b>(<b class="f">fold</b>(run, with: reserve) ?? <b class="s">"No safe path"</b>)',
    '',
    '<b class="k">extension</b> <b class="t">Planet</b> {',
    '    <b class="k">static let</b> arrakis = <b class="t">Planet</b>(<b class="s">"Arrakis"</b>, sand: <b class="k">true</b>)',
    '    <b class="k">static let</b> caladan = <b class="t">Planet</b>(<b class="s">"Caladan"</b>, sand: <b class="k">false</b>)',
    '}'
  ];

  // The week of the calendar: [day, date, [title, start hour, length in hours, colour]…].
  var WEEK = [
    ['Mon', 9, ['Water count', 1, 0.5, 1], ['Thopter service', 4.5, 1, 2]],
    ['Tue', 10, ['Water count', 1, 0.5, 1], ['Spice harvest', 3, 2, 5]],
    ['Wed', 11, ['Water count', 1, 0.5, 1], ['Guild audit', 5, 1.5, 4]],
    ['Thu', 12, ['Water count', 1, 0.5, 1], ['Heighliner arrives', 5.5, 1.5, 3]],
    ['Fri', 13, ['Water count', 1, 0.5, 1], ['Sietch council', 3, 1.5, 3]]
  ];

  function skin(app, n) {
    switch (app) {
      case 'code':
        return '<div class="sk-code"><aside><b>Navigator</b><span class="d">Sources</span><span class="on">Fold.swift</span><span>Route.swift</span><span>Heighliner.swift</span><span>Spice.swift</span>' +
          '<span class="d">Tests</span><span>FoldTests.swift</span><span>Package.swift</span></aside>' +
          '<div class="ed"><nav><span class="on">Fold.swift</span><span>Route.swift</span></nav><pre>' +
          SOURCE.map(function (line, i) { return '<p><i>' + (i + 1) + '</i>' + line + '</p>'; }).join('') + '</pre></div></div>';
      case 'safari':
        var page = PAGES[n];
        return '<div class="sk-web tone-' + n + '"><header><b>' + page.site + '</b>' + page.menu.map(function (m) { return '<span>' + m + '</span>'; }).join('') + '</header>' +
          '<div class="col"><figure></figure><small>' + page.kicker + '</small><h4>' + page.title + '</h4>' +
          page.text.map(function (t) { return '<p>' + t + '</p>'; }).join('') + '</div></div>';
      case 'terminal':
        return '<div class="sk-term"><p><b>~/guild/navigator</b> % swift build</p><p class="dim">Compiling Navigator (14 sources)</p><p class="ok">Build complete! (3.21s)</p>' +
          '<p><b>~/guild/navigator</b> % swift test</p><p class="dim">Test Suite \'All tests\' started</p><p class="ok">Executed 58 tests, with 0 failures</p>' +
          '<p><b>~/guild/navigator</b> % <u></u></p></div>';
      case 'notes':
        return '<div class="sk-notes"><aside><p class="on"><b>Deep desert</b><span>10:42&ensp;Stillsuit seals, thumper</span></p><p><b>Sietch stores</b><span>Yesterday&ensp;Water rings, lamps</span></p>' +
          '<p><b>Worm sign</b><span>Monday&ensp;Third ridge, at dawn</span></p><p><b>Spice coffee</b><span>3 Nov&ensp;Two measures, no more</span></p></aside>' +
          '<article><small>12 November 2026 at 10:42</small><h4>Deep desert</h4><ul><li class="done">Stillsuit seals</li><li class="done">Thumper, and the spare</li><li>Maker hooks</li>' +
          '<li>Fremkit</li><li>Paracompass</li><li>Spice coffee</li><li>Water for one more day</li></ul></article></div>';
      case 'mail':
        return '<div class="sk-mail"><aside>' +
          '<p class="on"><b>Spacing Guild</b><i>09:58</i><span>Your passage to Arrakis</span><em>Two berths on the heighliner, frigate deck 4.</em></p>' +
          '<p><b>Arrakeen water office</b><i>Yesterday</i><span>Your allowance for the month</span><em>Three litres more than the last one.</em></p>' +
          '<p><b>Sietch council</b><i>Yesterday</i><span>Gathering after the storm</span><em>Bring your own cup this time.</em></p>' +
          '<p><b>Harvester crew 7</b><i>Monday</i><span>A spotter is needed on Thursday</span><em>Worm sign is expected before noon.</em></p></aside>' +
          '<article><h4>Your passage to Arrakis</h4><small>Spacing Guild&ensp;09:58</small><p>Two berths on the heighliner, frigate deck 4, leaving Caladan orbit at 08:14. The fold takes no time at all. Boarding takes most of a day.</p>' +
          '<div><b>08:14</b><span>Deck 4, berths 21 and 22</span></div><p>Payment in spice was received.</p></article></div>';
      case 'messages':
        return '<div class="sk-msg"><header><i>ST</i><b>Sietch</b></header><div><p>Worm sign at the third ridge</p><p class="me">How big?</p><p>Big enough to ride</p>' +
          '<p class="me">I have the hooks</p><p class="me">Who brings the thumper?</p><p>It is already planted</p></div></div>';
      case 'calendar':
        return '<div class="sk-cal"><header><b>November 2026</b><span><i>Day</i><i class="on">Week</i><i>Month</i></span></header><div class="days">' +
          WEEK.map(function (day) {
            return '<div' + (day[1] === 12 ? ' class="today"' : '') + '><b><span>' + day[0] + '</span><u>' + day[1] + '</u></b>' + day.slice(2).map(function (e) {
              return '<em class="e' + e[3] + '" style="top:' + (2.1 + e[1] * 2.44).toFixed(2) + 'em;height:' + (e[2] * 2.44 - 0.12).toFixed(2) + 'em"><span>' + e[0] + '</span></em>';
            }).join('') + '</div>';
          }).join('') + '</div></div>';
      case 'music':
        return '<div class="sk-music"><div class="now"><em></em><div><b>Second Moon</b><span>Baliset Sessions</span><p class="seek"><i></i></p><p class="ctl"><i class="prev"></i><i class="pause"></i><i class="next"></i></p></div></div>' +
          '<ol><li class="on"><b>Second Moon</b><span>3:48</span></li><li><b>The Long Erg</b><span>4:12</span></li><li><b>Windtrap</b><span>5:01</span></li>' +
          '<li><b>Caladan Rain</b><span>4:36</span></li><li><b>Sandrider</b><span>6:20</span></li></ol></div>';
    }
    return '';
  }

  // A window: traffic lights, a title or an address field, then what the app shows.
  function makeWin(app, n) {
    var bar = '<span class="lights"><i></i><i></i><i></i></span>';
    if (app === 'safari') bar += '<span class="url"><i></i>' + PAGES[n || 0].url + '</span>';
    else bar += '<span class="win-title">' + TITLES[app] + '</span>';
    return el('div', 'win app-' + app, '<div class="win-bar">' + bar + '</div><div class="win-body">' + skin(app, n || 0) + '</div>');
  }

  // Generic app icons, drawn here: no app's own artwork.
  var GLYPHS = {
    finder: '<path class="f" d="M2.400 5.300c0-.7.500-1.200 1.200-1.200h2.700l1.200 1.300h4.900c.7 0 1.200.5 1.200 1.200v4.700c0 .7-.500 1.200-1.200 1.200H3.600c-.7 0-1.200-.5-1.200-1.200z"/>',
    code: '<path d="M6 4.500 2.500 8 6 11.500M10 4.500 13.500 8 10 11.500"/>',
    safari: '<circle cx="8" cy="8" r="5.300"/><path class="f" d="M10.600 5.400 9 9 5.400 10.600 7 7z"/>',
    terminal: '<path d="M3.500 5 6.500 8l-3 3M8.500 11h4"/>',
    mail: '<path d="M2.500 4.500h11v7h-11zM2.500 5 8 9.200 13.500 5"/>',
    messages: '<path class="f" d="M3 4h10v6.400H7.400L4.400 13v-2.600H3z"/>',
    calendar: '<path d="M3 4h10v9H3zM3 7h10"/>',
    notes: '<path d="M4 5h8M4 8h8M4 11h5"/>',
    music: '<path d="M6.300 11.300V4.600l5.600-1.300v6.600"/><circle class="f" cx="4.900" cy="11.400" r="1.500"/><circle class="f" cx="10.500" cy="10" r="1.500"/>',
    app: '<path d="M4 4h3v3H4zM9 4h3v3H9zM4 9h3v3H4zM9 9h3v3H9z"/>',
    desktop: '<path class="f" d="M2.500 3.500h6v9h-6zM9.800 3.500h3.700v4h-3.700zM9.800 8.800h3.700v3.700h-3.700z"/>',
    scene: '<path d="M2.500 5.500h5v5h-5zM9 4h4.500v8H9z"/>',
    command: '<path d="M6 6h4v4H6zM6 6V4.700A1.300 1.300 0 1 0 4.700 6zM10 6V4.700A1.300 1.300 0 1 1 11.300 6zM6 10v1.300A1.300 1.300 0 1 1 4.700 10zM10 10v1.300a1.300 1.300 0 1 0 1.300-1.300z"/>'
  };
  function ico(kind, running) {
    return '<span class="ico ico-' + kind + (running ? ' run' : '') + '"><svg viewBox="0 0 16 16" aria-hidden="true">' + (GLYPHS[kind] || GLYPHS.app) + '</svg></span>';
  }

  // A display: its menu bar with the front app's menus, the Dock, then a stand or a laptop's base.
  var MENUS = ['File', 'Edit', 'View', 'Window', 'Help'];
  var DOCK_APPS = ['finder', 'safari', 'mail', 'messages', 'calendar', 'notes', 'music', 'code', 'terminal'];
  function menubar(app, menus) {
    return '<b>' + app + '</b>' + (menus || MENUS).map(function (m) { return '<span>' + m + '</span>'; }).join('') +
      '<em><i class="mb-fold"></i><i class="mb-batt"></i><i class="mb-find"></i><span>Thu 12 Nov&ensp;10:42</span></em>';
  }
  function makeDisplay(kind, app, running) {
    var node = el('div', 'display ' + kind);
    var screen = el('div', 'screen');
    screen.appendChild(el('div', 'mbar', menubar(app, kind === 'laptop' ? MENUS.slice(0, 4) : MENUS)));
    screen.appendChild(el('div', 'dock', DOCK_APPS.map(function (a) {
      return ico(a, a === 'finder' || (running || '').indexOf(a) >= 0);
    }).join('')));
    if (kind === 'laptop') screen.appendChild(el('div', 'lnotch'));
    node.appendChild(el('div', kind === 'laptop' ? 'base' : 'stand'));
    node.appendChild(screen);
    return { node: node, screen: screen };
  }
  function frame(node, r) {
    node.style.left = r.x + 'px'; node.style.top = r.y + 'px';
    node.style.width = r.w + 'px'; node.style.height = r.h + 'px';
  }

  // A slot's frame inside a screen, between the menu bar and the Dock: a whole gap at the edges,
  // half of one between slots.
  function slotRect(w, h, f, bar, gap, dock) {
    var ah = h - bar - (dock || 0);
    var x0 = f[0] * w, x1 = (f[0] + f[2]) * w, y0 = f[1] * ah, y1 = (f[1] + f[3]) * ah;
    var left = f[0] < 0.001 ? gap : x0 + gap / 2, right = f[0] + f[2] > 0.999 ? w - gap : x1 - gap / 2;
    var top = f[1] < 0.001 ? gap : y0 + gap / 2, bottom = f[1] + f[3] > 0.999 ? ah - gap : y1 - gap / 2;
    return { x: left, y: bar + top, w: right - left, h: bottom - top };
  }

  // The keys of a chord go down one after the other, then the thing happens.
  function press(chord, then) {
    var keys = chord.querySelectorAll('kbd');
    if (still) { if (then) then(); return; }
    each(keys, function (key, i) { setTimeout(function () { key.classList.add('is-down'); }, i * 60); });
    setTimeout(function () { if (then) then(); }, keys.length * 60 + 60);
    setTimeout(function () { each(keys, function (key) { key.classList.remove('is-down'); }); }, keys.length * 60 + 420);
  }

  /* --- The desk: a MacBook and a display, windows piled up, and every one goes to its slot ------- */
  (function hero() {
    var box = $('desk');
    if (!box) return;
    var status = $('desk-status'), chord = $('hero-chord'), button = $('scatter');
    var BAR = 24, DOCK = 54, GAP = 8;
    var SCENES = {
      wide: { w: 1660, h: 690, d: { laptop: { x: 78, y: 283, w: 540, h: 349 }, main: { x: 742, y: 40, w: 900, h: 506 } } },
      narrow: { w: 700, h: 910, d: { main: { x: 20, y: 18, w: 660, h: 371 }, laptop: { x: 110, y: 548, w: 480, h: 310 } } }
    };
    // Where each window lives, and where the morning left it: on which display, as fractions of
    // that desktop. The pile is listed back to front.
    var PLAN = [
      { app: 'code', on: 'main', f: [0, 0, 0.58, 1], mess: ['laptop', 0.04, 0.05, 0.8, 0.84] },
      { app: 'safari', on: 'main', f: [0.58, 0, 0.42, 0.54], mess: ['main', 0.06, 0.05, 0.5, 0.8] },
      { app: 'notes', on: 'laptop', f: [0, 0, 0.58, 1], mess: ['main', 0.6, 0.12, 0.34, 0.62] },
      { app: 'terminal', on: 'main', f: [0.58, 0.54, 0.42, 0.46], mess: ['main', 0.34, 0.4, 0.4, 0.52] },
      { app: 'messages', on: 'laptop', f: [0.58, 0, 0.42, 1], mess: ['laptop', 0.5, 0.24, 0.45, 0.7] }
    ];

    var scene = fit(box, SCENES.wide.w, SCENES.wide.h);
    var mode = '', top = 20, tidyNow = still, touched = false;
    var displays = { main: makeDisplay('main', 'Code', 'safari notes messages code terminal'), laptop: makeDisplay('laptop', 'Notes', 'safari notes messages code terminal') };
    ['main', 'laptop'].forEach(function (id) { scene.inner.appendChild(displays[id].node); });

    var wins = PLAN.map(function (plan, i) {
      var slot = el('div', 'slot', '<span>' + NAMES[plan.app] + '</span>');
      displays[plan.on].screen.appendChild(slot);
      var node = makeWin(plan.app);
      node.style.zIndex = 2 + i;
      displays[plan.on].screen.appendChild(node);
      var win = { plan: plan, node: node, slotNode: slot, m: new Mover(node), landed: tidyNow };
      win.m.done = function () { if (win.aimHome) { win.landed = true; node.classList.remove('is-held'); settle(); } };
      grab(win);
      return win;
    });

    // One window has the keyboard, as on a Mac: its traffic lights are the coloured ones.
    function setKey(win) { wins.forEach(function (w) { w.node.classList.toggle('is-key', w === win); }); }
    function settle() {
      if (wins.every(function (w) { return w.landed; })) scene.inner.classList.remove('is-loose');
    }

    function arrange() {
      var next = box.clientWidth < 700 ? 'narrow' : 'wide';
      if (next === mode) return;
      mode = next;
      var sc = SCENES[mode];
      scene.size(sc.w, sc.h);
      for (var id in sc.d) frame(displays[id].node, sc.d[id]);
      wins.forEach(function (win) {
        var home = sc.d[win.plan.on], away = sc.d[win.plan.mess[0]], ms = win.plan.mess, area = away.h - BAR - DOCK;
        win.slot = mix(slotRect(home.w, home.h, win.plan.f, BAR, GAP, DOCK), { r: 0, s: 1 });
        win.heap = { x: away.x - home.x + ms[1] * away.w, y: away.y - home.y + BAR + ms[2] * area, w: ms[3] * away.w, h: ms[4] * area, r: 0, s: 1 };
        frame(win.slotNode, win.slot);
        win.m.set(tidyNow ? win.slot : win.heap);
      });
    }

    function heap() {
      tidyNow = false;
      scene.inner.classList.add('is-loose');
      wins.forEach(function (win, i) {
        win.landed = false; win.aimHome = false;
        win.node.style.zIndex = 2 + i;
        win.m.go(win.heap, { delay: i * 30, k: 120, c: 18 });
      });
      top = 20;
      setKey(wins[wins.length - 2]);
    }
    function tidy() {
      tidyNow = true;
      wins.forEach(function (win, i) { win.aimHome = true; win.m.go(win.slot, { delay: i * 80, k: 165, c: 20 }); });
      setKey(wins[0]);
    }
    function say(text) { if (status) status.textContent = text; }

    // A locked slot takes its window back: drag one away and let go.
    function grab(win) {
      var node = win.node, drag = null;
      node.addEventListener('pointerdown', function (e) {
        if (e.button) return;
        touched = true;
        drag = { id: e.pointerId, sx: e.clientX, sy: e.clientY, ox: win.m.cur.x, oy: win.m.cur.y };
        try { node.setPointerCapture(e.pointerId); } catch (err) {}
        win.landed = false; win.aimHome = false;
        scene.inner.classList.add('is-loose');
        node.classList.add('is-held');
        node.style.zIndex = ++top;
        setKey(win);
        e.preventDefault();
      });
      node.addEventListener('pointermove', function (e) {
        if (!drag || e.pointerId !== drag.id) return;
        var m = win.m;
        m.cur.x = m.aim.x = drag.ox + (e.clientX - drag.sx) / scene.scale;
        m.cur.y = m.aim.y = drag.oy + (e.clientY - drag.sy) / scene.scale;
        m.vel.x = m.vel.y = 0;
        m.paint();
      });
      function release(e) {
        if (!drag || e.pointerId !== drag.id) return;
        drag = null;
        win.aimHome = true;
        win.m.go(win.slot, { k: 165, c: 18 });
        say(NAMES[win.plan.app] + ' is back in its slot.');
      }
      node.addEventListener('pointerup', release);
      node.addEventListener('pointercancel', release);
    }

    arrange();
    if ('ResizeObserver' in window) new ResizeObserver(arrange).observe(box);
    setKey(still ? wins[0] : wins[wins.length - 2]);

    if (!still) {
      scene.inner.classList.add('is-loose');
      setTimeout(function () { press(chord, tidy); }, 1500);
      // Once, if nobody has tried: a window is pulled out of its slot and goes back by itself.
      setTimeout(function () {
        var win = wins[1];
        if (touched || !tidyNow || !win.landed || window.scrollY > 200) return;
        win.landed = false; win.aimHome = false;
        scene.inner.classList.add('is-loose');
        win.node.style.zIndex = ++top;
        win.node.classList.add('is-held');
        setKey(win);
        win.m.go({ x: win.slot.x - 190, y: win.slot.y + 90 }, { k: 80, c: 15 });
        setTimeout(function () { if (!touched) { win.aimHome = true; win.m.go(win.slot, { k: 165, c: 18 }); } }, 1000);
      }, 7000);
    }
    if (button) button.addEventListener('click', function () {
      touched = true;
      if (still) { say('Every window is in its slot.'); return; }
      heap();
      say('The windows are in a pile.');
      setTimeout(function () { press(chord, function () { tidy(); say('Every window is back in its slot.'); }); }, 1200);
    });
  })();

  /* --- Desktops, and the windows on them, as the scenes draw them --------------------------------- */
  // The desktops of a display, side by side: showing one slides the row.
  function deck(screen, tints) {
    var strip = el('div', 'strip'), shown = 0;
    var pages = tints.map(function (t) { return strip.appendChild(el('div', 'page tint-' + t)); });
    screen.insertBefore(strip, screen.firstChild);
    return {
      pages: pages,
      shown: function () { return shown; },
      show: function (i) { var moved = i !== shown; shown = i; strip.style.transform = 'translateX(' + (-i * 100) + '%)'; return moved; }
    };
  }
  // What hangs when a display changes desktop: its name, and a dot per desktop.
  function banner(node) {
    var timer = 0;
    node.innerHTML = '<span></span><em></em>';
    return function (name, i, count) {
      node.firstChild.textContent = name;
      var dots = '';
      for (var d = 0; d < count; d++) dots += '<u' + (d === i ? ' class="on"' : '') + '></u>';
      node.lastChild.innerHTML = dots;
      node.classList.add('is-on');
      clearTimeout(timer);
      timer = setTimeout(function () { node.classList.remove('is-on'); }, 1700);
    };
  }
  // A window that only sits in its slot.
  function put(page, app, rect, n, extra) {
    var node = makeWin(app, n);
    node.className += ' fixed' + (extra ? ' ' + extra : '');
    frame(node, rect);
    page.appendChild(node);
    return node;
  }
  // A window that travels: a spring holds its frame.
  function add(page, app, rect, n) {
    var node = makeWin(app, n);
    page.appendChild(node);
    return { node: node, app: app, rect: rect, m: new Mover(node, mix(rect, {})) };
  }
  function key(node) {
    each(node.parentNode.querySelectorAll('.win.is-key'), function (w) { w.classList.remove('is-key'); });
    node.classList.add('is-key');
  }

  /* --- The dive: six features, told by the scroll ------------------------------------------------
     The section is several screens tall and its stage stays in the window meanwhile. The scroll is
     the camera. It first goes forward, from the whole desk into the Main display, and the heading
     passes it by. Then each feature plays on that display as far as the page is scrolled, and
     backwards when it is scrolled back: slots are cut and windows open into them, one slot takes
     the desktop, a stack is gone through, the drawers come in. Each feature has its own desktop,
     and going to the next is a change of desktop, as on a Mac. For the restart and the travel
     setup the camera steps back to the desk.
     A frame only writes transforms, opacities and one clip: nothing is laid out again. The display
     is laid out at the size it has from closest and only ever made smaller, so its text stays
     sharp. */
  (function story() {
    var section = $('moves'), dive = $('dive'), host = $('stage'), stepsBox = $('steps'), nav = $('prog');
    if (!section || !dive || !host || !stepsBox || !nav) return;
    var inner = dive.querySelector('.dive-in'), head = dive.querySelector('.story-head'), lede = head.querySelector('.lede');
    var glowBox = dive.querySelector('.dive-glow'), pageBar = doc.querySelector('.bar');
    var caps = Array.prototype.slice.call(stepsBox.querySelectorAll('.step'));
    var kbds = caps.map(function (c) { return c.querySelectorAll('.chord kbd'); });
    var parts = caps.map(function (c) { return Array.prototype.slice.call(c.children); });

    // The film, in lengths of scroll: the way in, one length per feature, then a breath.
    var INTRO = 0.9, LEN = [1.25, 1.25, 1.4, 1.25, 1.5, 1.6], TAIL = 0.3, START = [], TOTAL = INTRO;
    LEN.forEach(function (l) { START.push(TOTAL); TOTAL += l; });
    TOTAL += TAIL;
    // Without motion a feature is one still picture: the moment of it that says the most.
    var POSTER = [0.95, 0.62, 0.17, 0.7, 0.95, 0.42];
    var LABELS = ['Layouts', 'Focus', 'Stacks', 'Drawers', 'Restart', 'Displays'];
    var DESKS = ['Navigator', 'Arrakis', 'Dispatches', 'Sietch'];
    var TRAVEL = ['Guild', 'Navigator · Code', 'Navigator · Safari', 'Navigator · Terminal'], TRAVEL_APP = ['Messages', 'Code', 'Safari', 'Terminal'];

    function r(t, a, b) { return clamp((t - a) / (b - a), 0, 1); }
    function io(x) { return x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2; }
    function out(x) { return 1 - Math.pow(1 - x, 3); }
    function lerp(a, b, t) { return a + (b - a) * t; }
    // From one place of the camera to another: a zoom is even to the eye when the scale is multiplied.
    function zoom(a, b, t) { return { x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t), s: a.s * Math.pow(b.s / a.s, t) }; }

    // A style is written only when it changes: most of the stage is at rest in any one frame.
    function T(node, v) { if (node._t !== v) { node._t = v; node.style.transform = v; } }
    function O(node, v) {
      v = v < 0.004 ? 0 : v > 0.996 ? 1 : Math.round(v * 400) / 400;
      if (node._o !== v) { node._o = v; node.style.opacity = v; }
    }
    // Shown is "as its parent is": a window of a display that is out of sight must not show through.
    function V(node, on) { on = !!on; if (node._v !== on) { node._v = on; node.style.visibility = on ? 'inherit' : 'hidden'; } }
    function C(node, cls, on) { on = !!on; var k = '_c' + cls; if (node[k] !== on) { node[k] = on; node.classList.toggle(cls, on); } }
    function say(node, text) { if (node._s !== text) { node._s = text; node.textContent = text; } }
    function px(v) { return v.toFixed(2) + 'px'; }

    // The light the display throws on the night around it, in the colour of each wallpaper. Each is
    // a small picture, drawn once and enlarged by the compositor: a gradient laid out at the size of
    // a wide window would be kept in memory at that size, four times over.
    var glows = [[44, 92, 236, 0.62], [212, 104, 60, 0.5], [24, 150, 142, 0.5], [108, 84, 230, 0.6]].map(function (c) {
      var node = el('canvas'), g = node.getContext && node.getContext('2d');
      node.width = 240; node.height = 150;
      if (g) {
        var shade = g.createRadialGradient(120, 120, 0, 120, 120, 120);
        [1, 0.74, 0.42, 0.15, 0].forEach(function (a, k) { shade.addColorStop(k / 4, 'rgba(' + c[0] + ',' + c[1] + ',' + c[2] + ',' + (c[3] * a).toFixed(3) + ')'); });
        g.scale(1, 150 / 240);
        g.fillStyle = shade;
        g.fillRect(0, 0, 240, 240);
      }
      return glowBox.appendChild(node);
    });

    // Where the film is: six bars, filled as far as each feature is played. A bar is also a way there.
    var segBox = nav.appendChild(el('div', 'dive-segs')), count = nav.appendChild(el('p', 'dive-count'));
    var segs = LABELS.map(function (name, i) {
      var b = el('button', '', '<i><u></u></i><span>' + name + '</span>');
      b.type = 'button';
      b.setAttribute('aria-label', name + ': part ' + (i + 1) + ' of ' + LABELS.length);
      b.addEventListener('click', function () { jump(i); });
      segBox.appendChild(b);
      return { node: b, fill: b.querySelector('u') };
    });

    /* Everything on the stage, built for one of two drawings: the large one, or a smaller display
       with larger things on it for a narrow page. Frames are in pixels of the drawing. */
    var S = null;
    function build(small) {
      host.innerHTML = '';
      var DW = small ? 640 : 1040, DH = small ? 470 : 650, BAR = 26, DOCK = 60, GAP = small ? 8 : 10;
      var LW = small ? 400 : 540, LH = small ? 259 : 349;
      function at(f) { return slotRect(DW, DH, f, BAR, GAP, DOCK); }
      function lat(f) { return slotRect(LW, LH, f, 24, 8, 54); }
      function u(v) { return 'calc(var(--u) * ' + v.toFixed(2) + ')'; }
      function place(node, q) {
        var st = node.style;
        st.left = u(q.x); st.top = u(q.y);
        if (q.w != null) { st.width = u(q.w); st.height = u(q.h); }
        return node;
      }
      function win(page, app, rect, n, front) {
        var node = makeWin(app, n);
        if (front) node.classList.add('is-key');
        // A narrow window has room for the name of the site, not for the whole address.
        if (small && app === 'safari') node.querySelector('.url').lastChild.textContent = PAGES[n || 0].url.split('/')[0];
        page.appendChild(place(node, rect));
        return { node: node, rect: rect, app: app };
      }
      // The middle of an app's icon in the Dock: a window that opens grows out of it.
      function dockAt(w, h, dk, app) {
        var step = dk * 1.16, k = DOCK_APPS.indexOf(app);
        return { x: w / 2 - (DOCK_APPS.length * step + dk * 0.16) / 2 + dk * 0.66 + k * step, y: h - dk * 0.88 };
      }
      function display(kind, app, tints) {
        var d = makeDisplay(kind, app, '');
        var box = el('div', 'dv-pages');
        d.screen.insertBefore(box, d.screen.firstChild);
        d.pages = tints.map(function (t) { return box.appendChild(el('div', 'page tint-' + t)); });
        d.app = d.screen.querySelector('.mbar b');
        d.dock = {};
        each(d.screen.querySelectorAll('.dock .ico'), function (icon, k) { d.dock[DOCK_APPS[k]] = icon; });
        d.login = d.screen.appendChild(el('div', 'dv-login', '<i></i><b><u></u><u></u><u></u><u></u><u></u></b>'));
        d.dots = d.login.querySelectorAll('u');
        d.boot = d.screen.appendChild(el('div', 'dv-boot', '<b><i></i></b>'));
        d.bar = d.boot.querySelector('i');
        d.name = d.node.appendChild(el('span', 'dv-name', kind === 'main' ? 'Main' : 'Laptop'));
        d.foot = d.node.firstChild;
        host.appendChild(d.node);
        return d;
      }

      var main = display('main', 'Finder', [0, 1, 2, 3]);
      var lap = display('laptop', 'Messages', [3, 0, 0, 0]);

      // Navigator: two cuts make three slots, and each app opens into its own.
      var L0 = [['code', [0, 0, 0.58, 1]], ['safari', [0.58, 0, 0.42, 0.56]], ['terminal', [0.58, 0.56, 0.42, 0.44]]];
      var area = DH - BAR - DOCK;
      var cutV = place(el('i', 'dv-cut v'), { x: DW * 0.58, y: BAR + GAP }), cutH = place(el('i', 'dv-cut h'), { x: DW * 0.58, y: BAR + area * 0.56 });
      cutV.style.height = u(area - GAP * 2);
      cutH.style.width = u(DW * 0.42 - GAP);
      main.pages[0].appendChild(cutV);
      main.pages[0].appendChild(cutH);
      var slots = L0.map(function (s) {
        return main.pages[0].appendChild(place(el('div', 'slot', '<b>' + ico(s[0]) + NAMES[s[0]] + '</b>'), at(s[1])));
      });
      var w0 = L0.map(function (s, i) { return win(main.pages[0], s[0], at(s[1]), 0, !i); });
      var from0 = L0.map(function (s) { return dockAt(DW, DH, 36, s[0]); });

      // Arrakis: three columns. The middle one is laid out as wide as the desktop and cut down to
      // its slot: Focus takes the cut away, and what is in the window keeps to its edges.
      var FULL = at([0, 0, 1, 1]), MID = at([0.27, 0, 0.46, 1]);
      var sideA = win(main.pages[1], 'notes', at([0, 0, 0.27, 1])).node, sideB = win(main.pages[1], 'calendar', at([0.73, 0, 0.27, 1])).node;
      sideA.classList.add('dv-side'); sideB.classList.add('dv-side');
      var fshadow = main.pages[1].appendChild(place(el('div', 'dv-fshadow'), MID));
      var fwin = win(main.pages[1], 'safari', FULL, 1, true).node;
      fwin.classList.add('dv-fwin');
      var roomEm = MID.w / 12.5;
      fwin.querySelector('.col').style.gridTemplateColumns = 'minmax(0, ' + Math.min(31, roomEm - 3.6).toFixed(1) + 'em)';
      fwin.querySelector('.url').style.maxWidth = Math.min(26, roomEm - 13).toFixed(1) + 'em';
      var focus = { node: fwin, left: MID.x - FULL.x, right: FULL.x + FULL.w - MID.x - MID.w, slot: MID.w,
        edge: [fwin.querySelector('.lights'), fwin.querySelector('.sk-web header')], mid: [fwin.querySelector('.url'), fwin.querySelector('.col')] };

      // Dispatches: three Safari windows share the large slot.
      var STACK = at([0, 0, 0.66, 1]);
      var stack = PAGES.map(function (page, i) { return win(main.pages[2], 'safari', STACK, i); });
      win(main.pages[2], 'music', at([0.66, 0, 0.34, 1]));
      var mark = main.pages[2].appendChild(place(el('div', 'dv-mark'), { x: STACK.x + STACK.w / 2, y: STACK.y + STACK.h - 50 }));

      // Sietch: mail and a terminal, under the display's two drawers.
      win(main.pages[3], 'mail', at([0, 0, 0.6, 1]), 0, true);
      win(main.pages[3], 'terminal', at([0.6, 0, 0.4, 1]));
      var dim = main.pages[3].appendChild(el('div', 'dv-dim'));
      var DRAWER = DW * (small ? 0.44 : 0.36);
      function drawer(side, apps) {
        var node = el('div', 'dv-drawer ' + side), tall = (area - GAP * (apps.length + 1)) / apps.length;
        node.style.width = u(DRAWER);
        apps.forEach(function (app, i) {
          var w = makeWin(app);
          if (!i) w.classList.add('is-key');
          node.appendChild(place(w, { x: GAP, y: GAP + i * (tall + GAP), w: DRAWER - GAP * 2, h: tall }));
        });
        main.screen.appendChild(node);
        return node;
      }
      var left = drawer('left', ['notes', 'messages']), right = drawer('right', ['calendar']);
      var pill = main.screen.appendChild(el('div', 'dv-pill', '<span></span><em></em>'));

      // The Laptop: its own desktop, then the three it gains when it travels alone.
      var lw = [win(lap.pages[0], 'messages', lat([0, 0, 0.42, 1]), 0, true), win(lap.pages[0], 'calendar', lat([0.42, 0, 0.58, 1]))];
      ['code', 'safari', 'terminal'].forEach(function (app, i) { win(lap.pages[1 + i], app, lat([0, 0, 1, 1]), 0, true); });
      var lfrom = [dockAt(LW, LH, 32, 'messages'), dockAt(LW, LH, 32, 'calendar')];
      var ndrop = lap.screen.appendChild(el('div', 'dv-ndrop', '<span></span><em></em>'));
      ['messages', 'calendar'].forEach(function (app) { lap.dock[app].classList.add('run'); });

      // The two configurations, named as their owner would, and the desktops of the Laptop.
      var cfg = host.appendChild(el('p', 'dv-cfg', '<span><b>Arrakeen</b><i>Laptop + Main</i></span><span><b>Open desert</b><i>Laptop</i></span>'));
      var chipBox = host.appendChild(el('p', 'dv-chips', '<i>Desktops of the Laptop</i>'));
      var chips = [['desktop', 'Guild'], ['code', 'Code'], ['safari', 'Safari'], ['terminal', 'Terminal']].map(function (c) {
        return chipBox.appendChild(el('span', 'dv-chip', ico(c[0]) + c[1]));
      });

      return { small: small, DW: DW, DH: DH, LW: LW, LH: LH, main: main, lap: lap, slotsAt: L0.map(function (s) { return at(s[1]); }),
        cutV: cutV, cutH: cutH, slots: slots, w0: w0, from0: from0, sideA: sideA, sideB: sideB, fshadow: fshadow, focus: focus,
        stack: stack, STACK: STACK, mark: mark, front: -1, dim: dim, left: left, right: right, pill: pill, pillAt: -1,
        lw: lw, lfrom: lfrom, ndrop: ndrop, dropAt: -1, cfg: cfg, cfgs: cfg.children, chipBox: chipBox, chips: chips };
    }

    /* Where things stand, in pixels of the page: worked out when the stage changes size, never in
       a frame. Beside the text on a wide window, above it on a tall one. */
    var G = null, flat = false;
    function measure() {
      var VW = dive.clientWidth, VH = dive.clientHeight;
      if (!VW || !VH) return;
      // Beside the words wherever the window is wider than tall, a phone on its side included.
      var small = VW < 700, wide = VW >= 640 && VW / VH >= 1.25;
      if (!S || S.small !== small) S = build(small);
      dive.classList.toggle('is-wide', wide);
      var top = pageBar ? pageBar.offsetHeight : 38, g, ax, ay, aw, ah, cap, navH = 46;
      if (wide) {
        g = clamp(VW * 0.032, 24, 110);
        var cw = clamp(VW * 0.26, 300, 860);
        if (cw >= 440) navH = 78;
        ax = g * 2 + cw; aw = VW - ax - g;
        ay = top + clamp(VH * 0.04, 18, 70); ah = VH - ay - clamp(VH * 0.075, 36, 140);
        cap = { x: g, y: ay, w: cw, h: ah - navH };
      } else {
        g = small ? 16 : 28;
        ax = g; aw = VW - g * 2; ay = top + (small ? 14 : 22);
        ah = Math.min(aw * S.DH / S.DW * 1.035, VH * 0.43);
        cap = { x: g, y: ay + ah + (small ? 18 : 28), w: aw, h: 0 };
        cap.h = Math.max(120, VH - cap.y - navH - 12);
      }
      var sw = Math.round(Math.min(aw * 0.97, ah * (wide ? 0.93 : 0.955) * S.DW / S.DH)), sh = Math.round(sw * S.DH / S.DW);
      var lw = Math.round(Math.min(aw * (wide ? 0.6 : 0.84), ah * 0.6 * S.LW / S.LH)), lh = Math.round(lw * S.LH / S.LW);
      var U = sw / S.DW, UL = lw / S.LW;
      function size(d, w, h, unit) {
        d.node.style.width = w + 'px'; d.node.style.height = h + 'px';
        d.node.style.setProperty('--u', unit.toFixed(4) + 'px');
        d.w = w; d.h = h;
      }
      size(S.main, sw, sh, U);
      size(S.lap, lw, lh, UL);

      // The desk, as the hero shows it: the Laptop low on the left, Main on the right.
      function deskIn(b) {
        var sc = wide ? { w: 1660, h: 740, m: [742, 40, 900], l: [78, 330, 540] } : { w: 700, h: 480, m: [250, 10, 440], l: [44, 258, 290] };
        var f = Math.min(b.w / sc.w, b.h / sc.h), ox = b.x + (b.w - sc.w * f) / 2, oy = b.y + (b.h - sc.h * f) / 2;
        var mw = sc.m[2] * f, lw2 = sc.l[2] * f;
        return { m: { x: ox + sc.m[0] * f + mw / 2, y: oy + sc.m[1] * f + mw * S.DH / S.DW / 2, s: mw / sw },
          l: { x: ox + sc.l[0] * f + lw2 / 2, y: oy + sc.l[1] * f + lw2 * S.LH / S.LW / 2, s: lw2 / lw } };
      }
      // Before the camera moves, the desk has the room the heading leaves under it.
      var under = head.offsetTop + head.offsetHeight + clamp(VH * 0.035, 18, 70), w0 = wide ? Math.min(VW * 0.7, (VH - under) * 2.6) : aw;
      var far = deskIn({ x: (VW - w0) / 2, y: under, w: w0, h: Math.max(VH * 0.3, VH - under - clamp(VH * 0.04, 16, 60)) });
      var desk = deskIn(wide ? { x: ax, y: ay + ah * 0.12, w: aw, h: ah * 0.84 } : { x: ax, y: ay + 30, w: aw, h: ah - 34 });
      var rest = { x: ax + aw / 2, y: ay + ah * (wide ? 0.485 : 0.5), s: 1 }, alone = { x: ax + aw / 2, y: ay + ah * 0.49, s: 1 };
      var side = wide ? aw * 0.45 : VW * 0.8;
      // The Laptop comes back into the picture from under it, or from the side where the words are under.
      var back = wide ? { x: desk.l.x - aw * 0.05, y: desk.l.y + VH * 0.5, s: desk.l.s * 1.25 } : { x: desk.l.x - side, y: desk.l.y, s: desk.l.s };

      // The notes of the far view keep their size on the page whatever the drawing is scaled by.
      var fs = clamp(aw * 0.0165, 10.5, 24);
      S.main.name.style.fontSize = (fs * 0.82 / desk.m.s).toFixed(1) + 'px';
      S.lap.name.style.fontSize = (fs * 0.82 / desk.l.s).toFixed(1) + 'px';
      function note(node, y, size) {
        node.style.left = ax + 'px'; node.style.top = Math.round(y) + 'px';
        node.style.width = aw + 'px'; node.style.fontSize = size.toFixed(1) + 'px';
      }
      note(S.cfg, ay, fs);
      note(S.chipBox, alone.y + lh / 2 + UL * 31 + fs * 0.9, fs * 0.86);
      // A chip of a travelling desktop leaves from the slot of Main it was.
      S.chips.forEach(function (chip, k) {
        if (!k) return;
        var q = S.slotsAt[k - 1];
        chip.dx = desk.m.x + (q.x + q.w / 2 - S.DW / 2) * U * desk.m.s - (S.chipBox.offsetLeft + chip.offsetLeft + chip.offsetWidth / 2);
        chip.dy = desk.m.y + (q.y + q.h / 2 - S.DH / 2) * U * desk.m.s - (S.chipBox.offsetTop + chip.offsetTop + chip.offsetHeight / 2);
      });

      // The light is drawn small and enlarged: a soft gradient loses nothing, and a layer the size
      // of the window is not kept for each wallpaper.
      glowBox.style.height = Math.round(400 * sh * 2.3 / (sw * 2.3)) + 'px';
      var st = dive.style;
      st.setProperty('--cx', cap.x + 'px'); st.setProperty('--cy', Math.round(cap.y) + 'px');
      st.setProperty('--cw', cap.w + 'px'); st.setProperty('--ch', Math.round(cap.h) + 'px');

      // How much scroll one length of the film is. A share of the window would make the film far
      // too long on a tall display: a feature should take a few turns of the wheel, wherever.
      var unit = still ? 420 : clamp(VH * 0.9, 640, 1000);
      if (!flat) section.style.height = Math.round(VH + unit * TOTAL) + 'px';
      G = { VW: VW, VH: VH, unit: unit, U: U, UL: UL, wide: wide, rest: rest, far: far, desk: desk, alone: alone,
        deskOff: back, gone: { x: desk.m.x + side, y: desk.m.y, s: desk.m.s * 0.9 },
        gs: sw * 2.3 / 400, gh: Math.round(400 * sh * 2.3 / (sw * 2.3)), shift: clamp(cap.w * 0.07, 22, 60) };
      cur = null;
      kick();
    }

    function pose(d, p, tilt) {
      var x = p.x - d.w / 2, y = p.y - d.h / 2;
      // At rest it lies on whole pixels: text is sharpest there.
      if (p.s === 1 && !tilt) { x = Math.round(x); y = Math.round(y); }
      T(d.node, 'translate3d(' + px(x) + ',' + px(y) + ',0)' + (tilt ? ' perspective(' + Math.round(d.w * 2.4) + 'px) rotateX(' + tilt.toFixed(2) + 'deg)' : '') + ' scale(' + p.s.toFixed(4) + ')');
    }
    // A window that opens grows out of the Dock: e goes from 0, in the Dock, to 1, in its slot.
    function grow(w, e, from, unit) {
      var q = w.rect, s = 0.1 + 0.9 * e;
      var x = lerp(from.x, q.x + q.w / 2, e) - q.w * s / 2 - q.x, y = lerp(from.y, q.y + q.h / 2, e) - q.h * s / 2 - q.y;
      T(w.node, 'translate3d(' + px(x * unit) + ',' + px(y * unit) + ',0) scale(' + s.toFixed(4) + ')');
      O(w.node, r(e, 0, 0.3));
    }
    function pages(d, at) {
      d.pages.forEach(function (page, i) {
        var away = i - at, seen = Math.abs(away) < 0.999;
        V(page, seen);
        if (seen) T(page, 'translate3d(' + (away * 100).toFixed(3) + '%,0,0)');
      });
    }
    function dots(node, name, i, n) {
      var html = '';
      for (var d = 0; d < n; d++) html += '<u' + (d === i ? ' class="on"' : '') + '></u>';
      node.firstChild.textContent = name;
      node.lastChild.innerHTML = html;
    }
    function down(list, a, b, on) { for (var k = a; k < b; k++) C(list[k], 'is-down', on); }
    function near(t, at) { return !still && t > at - 0.012 && t < at + 0.06; }

    /* One frame: the whole stage as it is when the page is scrolled `sc` pixels into the section. */
    function render(sc) {
      var VW = G.VW, VH = G.VH, U = G.U, UL = G.UL, i;
      var P = clamp(sc / G.unit, 0, TOTAL), enter = clamp(1 + sc / VH, 0, 1), over = still ? 0 : Math.max(0, sc - G.unit * TOTAL);
      if (still) {
        // No film: the picture before it starts, then one picture per feature.
        enter = 1;
        if (P < START[0] * 0.5) P = 0;
        else { i = 0; while (i < 5 && P >= START[i + 1]) i++; P = START[i] + POSTER[i] * LEN[i]; }
      }
      var q = P / INTRO, t = START.map(function (s, k) { return clamp((P - s) / LEN[k], 0, 1); });
      var ci = -1;
      for (i = 0; i < START.length; i++) if (P >= START[i]) ci = i;
      var t0 = t[0], t1 = t[1], t2 = t[2], t3 = t[3], t4 = t[4], t5 = t[5];

      // The camera. In: from the desk to Main. Back to the desk for the restart. Then Main is unplugged.
      var into = io(r(q, 0.02, 0.94)), back = io(r(t4, 0.2, 0.48)), un = io(r(t5, 0.14, 0.36));
      var mp = un > 0 ? zoom(G.desk.m, G.gone, un) : back > 0 ? zoom(G.rest, G.desk.m, back) : zoom(G.far.m, G.rest, into);
      var lp, lo;
      if (un > 0) { lp = zoom(G.desk.l, G.alone, un); lo = 1; }
      else if (t4 > 0) { lp = zoom(G.deskOff, G.desk.l, back); lo = r(back, 0.05, 0.5); }
      else {
        // The Laptop is nearer than Main: it grows faster and leaves by the corner.
        lp = { x: G.far.l.x - into * VW * 0.52, y: G.far.l.y + into * VH * 0.2 + (1 - enter) * VH * 0.13, s: G.far.l.s * (1 + 1.7 * into) };
        lo = 1 - r(into, 0.3, 0.72);
      }
      if (into < 1) mp.y += (1 - enter) * VH * 0.07;
      pose(S.main, mp, into < 1 ? 15 * (1 - into) : 0);
      // Where the words are under the display, its stand would stand in them: it is there from afar only.
      if (!G.wide) O(S.main.foot, Math.max(1 - r(into, 0.5, 0.9), back));
      else O(S.main.foot, 1);
      O(S.main.node, 1 - r(un, 0.25, 0.9));
      V(S.main.node, un < 0.999);
      V(S.lap.node, lo > 0);
      if (lo > 0) { pose(S.lap, lp, into < 1 ? 15 * (1 - into) : 0); O(S.lap.node, lo); }

      // The heading is nearest of all: it passes the camera first.
      var hs = 1 + 1.3 * io(r(q, 0, 0.6));
      V(head, q < 0.56);
      T(head, 'translate3d(0,' + px((1 - enter) * VH * 0.05 - r(q, 0, 0.6) * VH * 0.07) + ',0) scale(' + hs.toFixed(4) + ')');
      O(head, (0.35 + 0.65 * enter) * (1 - r(q, 0.12, 0.5)));
      O(lede, 1 - r(q, 0, 0.2));

      // Which desktop Main shows: one per feature, and back to the first before the restart.
      var off = io(r(t1, 0, 0.14)) + io(r(t2, 0, 0.14)) + io(r(t3, 0, 0.14)) - 3 * io(r(t4, 0, 0.14));
      pages(S.main, off);
      var named = -1, shown = 0;
      [t1, t2, t3, t4].forEach(function (tk, k) {
        // Before the restart the name has less time: it is gone when the screen goes black.
        var v = k < 3 ? r(tk, 0.07, 0.13) * (1 - r(tk, 0.25, 0.31)) : r(tk, 0.06, 0.11) * (1 - r(tk, 0.14, 0.17));
        if (v > shown) { shown = v; named = k; }
      });
      if (named >= 0 && S.pillAt !== named) { S.pillAt = named; dots(S.pill, DESKS[(named + 1) % 4], (named + 1) % 4, 4); }
      O(S.pill, shown);
      T(S.pill, 'translate3d(-50%,' + px((shown - 1) * 16 * U) + ',0) scale(' + (0.9 + 0.1 * shown).toFixed(3) + ')');

      // The restart: black, a bar, the login, then every window again.
      var dark = r(t4, 0.16, 0.24), lit = r(t4, 0.63, 0.69), gone = t4 >= 0.24;
      [S.main, S.lap].forEach(function (d) {
        var black = d === S.main ? dark : (t4 > 0 && t4 < 0.46 ? 1 : dark);
        V(d.boot, t4 > 0.16 && t4 < 0.52);
        O(d.boot, black * (1 - r(t4, 0.46, 0.52)));
        T(d.bar, 'scaleX(' + r(t4, 0.24, 0.46).toFixed(4) + ')');
        V(d.login, gone && t4 < 0.69);
        O(d.login, 1 - lit);
        each(d.dots, function (dot, k) { O(dot, t4 >= 0.53 + k * 0.02 ? 1 : 0); });
      });

      // Navigator: the cuts, the slots, and the apps opening into them.
      T(S.cutV, 'scaleY(' + io(r(q, 0.5, 0.82)).toFixed(4) + ')');
      T(S.cutH, 'scaleX(' + io(r(q, 0.74, 1)).toFixed(4) + ')');
      O(S.cutV, 1 - r(t0, 0.26, 0.36)); O(S.cutH, 1 - r(t0, 0.26, 0.36));
      S.slots.forEach(function (slot, k) {
        var a = 0.06 + k * 0.07;
        O(slot, r(t0, a, a + 0.1));
        T(slot.firstChild, 'scale(' + (0.7 + 0.3 * out(r(t0, a + 0.02, a + 0.14))).toFixed(3) + ')');
      });
      S.w0.forEach(function (w, k) {
        var e = gone ? out(r(t4, 0.69 + k * 0.03, 0.79 + k * 0.03)) : out(r(t0, 0.4 + k * 0.14, 0.58 + k * 0.14));
        V(w.node, e > 0);
        if (e > 0) grow(w, e, S.from0[k], U);
      });
      S.lw.forEach(function (w, k) {
        var e = gone ? out(r(t4, 0.76 + k * 0.03, 0.86 + k * 0.03)) : 1;
        V(w.node, e > 0);
        if (e > 0) grow(w, e, S.lfrom[k], UL);
      });
      var page = Math.round(off), opened = gone ? t4 >= 0.72 : t0 >= 0.5;
      say(S.main.app, page === 0 ? (opened ? 'Code' : 'Finder') : page === 3 ? 'Mail' : 'Safari');
      C(S.main.dock.finder, 'run', true);
      C(S.main.dock.code, 'run', opened);
      C(S.main.dock.safari, 'run', gone ? t4 >= 0.75 : t0 >= 0.64);
      C(S.main.dock.terminal, 'run', gone ? t4 >= 0.78 : t0 >= 0.78);
      ['mail', 'messages', 'calendar', 'notes', 'music'].forEach(function (app) { C(S.main.dock[app], 'run', gone ? t4 >= 0.86 : t1 > 0.02); });

      // Focus: the cut is taken away from the middle window, the two beside it are gone, and back.
      var f = io(r(t1, 0.3, 0.5)) - io(r(t1, 0.74, 0.92)), fl = S.focus.left * (1 - f) * U, fr = S.focus.right * (1 - f) * U;
      var clip = 'inset(0 ' + px(fr) + ' 0 ' + px(fl) + ' round 0.95em)';
      if (S.focus.clip !== clip) { S.focus.clip = clip; S.focus.node.style.clipPath = clip; S.focus.node.style.webkitClipPath = clip; }
      S.focus.edge.forEach(function (n) { T(n, 'translate3d(' + px(fl) + ',0,0)'); });
      S.focus.mid.forEach(function (n) { T(n, 'translate3d(' + px((fl - fr) / 2) + ',0,0)'); });
      // The shadow is a box that is only stretched: under the window, nothing of it shows but the shade.
      T(S.fshadow, 'translate3d(' + px(-S.focus.left * f * U) + ',0,0) scaleX(' + (1 + (S.focus.left + S.focus.right) * f / S.focus.slot).toFixed(4) + ')');
      [S.sideA, S.sideB].forEach(function (n) {
        O(n, 1 - r(f, 0, 0.55));
        T(n, 'scale(' + (1 - 0.06 * r(f, 0, 0.55)).toFixed(4) + ')');
      });
      down(kbds[1], 0, 4, near(t1, 0.3) || near(t1, 0.74));

      // Stacks: three windows seen apart, then one on the other, then gone through, front to back.
      var apart = 1 - io(r(t2, 0.2, 0.36)), turns = [0.42, 0.58, 0.74].map(function (a) { return r(t2, a, a + 0.14); });
      var done = (turns[0] >= 0.5) + (turns[1] >= 0.5) + (turns[2] >= 0.5), front = (2 + done) % 3;
      var moving = -1, mv = 0;
      turns.forEach(function (x, k) { if (x > 0 && x < 1) { moving = (2 + k) % 3; mv = x; } });
      S.stack.forEach(function (w, k) {
        var depth = (k - front + 3) % 3, s = 1 - 0.14 * apart, x = (2 - depth) * 0.07 * apart * S.STACK.w, y = (2 - depth) * 0.07 * apart * S.STACK.h, turn = 0;
        if (k === moving) {
          // The one in front slides off the pile, and goes back in under it.
          var o = mv < 0.5 ? out(mv * 2) : 1 - io(mv * 2 - 1);
          x += o * S.STACK.w * 0.2; y += o * S.STACK.h * 0.035; turn = o * 2.4; s *= 1 - 0.05 * o;
        }
        T(w.node, 'translate3d(' + px(x * U) + ',' + px(y * U) + ',0) rotate(' + turn.toFixed(2) + 'deg) scale(' + s.toFixed(4) + ')');
        var z = 5 - depth;
        if (w.z !== z) { w.z = z; w.node.style.zIndex = z; }
        C(w.node, 'is-key', depth === 0);
      });
      if (S.front !== front) {
        S.front = front;
        var order = (front + 1) % 3;
        S.mark.innerHTML = '<b>Safari</b>' + PAGES[front].title + '<em>' + [0, 1, 2].map(function (k) { return '<u' + (k === order ? ' class="on"' : '') + '></u>'; }).join('') + '</em>';
      }
      O(S.mark, r(t2, 0.36, 0.42));
      down(kbds[2], 0, 4, near(t2, 0.42) || near(t2, 0.58) || near(t2, 0.74));

      // Drawers: other windows come in over the layout, from the left, then from the right, and go.
      var dl = out(r(t3, 0.22, 0.4)) - io(r(t3, 0.76, 0.88)), dr = out(r(t3, 0.46, 0.64)) - io(r(t3, 0.8, 0.92));
      V(S.left, dl > 0.001); V(S.right, dr > 0.001);
      T(S.left, 'translate3d(' + (-(1 - dl) * 106).toFixed(3) + '%,0,0)');
      T(S.right, 'translate3d(' + ((1 - dr) * 106).toFixed(3) + '%,0,0)');
      O(S.dim, 0.3 * Math.max(dl, dr));
      down(kbds[3], 0, 4, near(t3, 0.22) || near(t3, 0.76));
      down(kbds[3], 4, 8, near(t3, 0.46) || near(t3, 0.8));

      // One setup per set of displays: Main is unplugged, and its slots are desktops of the Laptop.
      var hops = [0.44, 0.6, 0.76], lat = 0, drop = 0;
      hops.forEach(function (a, k) {
        lat += io(r(t5, a, a + 0.1));
        // The name hangs from the notch until the next desktop comes; the last one stays.
        drop = Math.max(drop, r(t5, a + 0.03, a + 0.07) * (k < 2 ? 1 - r(t5, a + 0.13, a + 0.155) : 1));
      });
      pages(S.lap, lat);
      var lpage = Math.round(lat);
      say(S.lap.app, TRAVEL_APP[lpage]);
      if (S.dropAt !== lpage) { S.dropAt = lpage; dots(S.ndrop, TRAVEL[lpage], lpage, 4); }
      T(S.ndrop, 'translate3d(-50%,' + ((drop - 1) * 100).toFixed(2) + '%,0)');
      ['code', 'safari', 'terminal'].forEach(function (app) { C(S.lap.dock[app], 'run', un > 0.5); });
      var far = r(t4, 0.42, 0.52);
      O(S.main.name, far * (1 - r(t5, 0.12, 0.2))); O(S.lap.name, far * (1 - r(t5, 0.12, 0.2)));
      V(S.cfg, t5 > 0.02);
      O(S.cfg, r(t5, 0.02, 0.1));
      T(S.cfg, 'translate3d(0,' + px((r(t5, 0.02, 0.1) - 1) * 10) + ',0)');
      C(S.cfgs[0], 'is-on', un <= 0.5); C(S.cfgs[1], 'is-on', un > 0.5);
      V(S.chipBox, t5 > 0.15);
      O(S.chipBox.firstChild, r(t5, 0.3, 0.38));
      S.chips.forEach(function (chip, k) {
        var e = k ? out(r(t5, 0.15 + k * 0.03, 0.33 + k * 0.03)) : 1;
        O(chip, k ? r(e, 0, 0.25) : r(t5, 0.28, 0.36));
        T(chip, k ? 'translate3d(' + px(chip.dx * (1 - e)) + ',' + px(chip.dy * (1 - e)) + ',0) scale(' + (1.5 - 0.5 * e).toFixed(3) + ')' : 'none');
        C(chip, 'is-on', un > 0.5 && k === lpage);
      });

      // The light around the display: its wallpaper's, out while the Mac is off, and it follows the camera.
      var level = (0.45 + 0.55 * into) * (0.4 + 0.6 * enter) * (gone ? lit : 1 - dark), gx = lerp(mp.x, lp.x, un), gy = lerp(mp.y, lp.y, un);
      T(glowBox, 'translate3d(' + px(lerp(VW / 2, gx, 0.8) - 200) + ',' + px(lerp(VH / 2, gy, 0.8) - G.gh / 2) + ',0) scale(' + (G.gs * lerp(0.55, 1, into) * lerp(1, 0.78, back)).toFixed(4) + ')');
      glows.forEach(function (glow, k) { O(glow, level * Math.max(0, 1 - Math.abs(k - off))); });

      // The words: a title and a sentence for the feature that plays, each layer at its own speed.
      caps.forEach(function (cap, k) {
        var inn = k ? r(t[k], 0.03, 0.15) : r(q, 0.8, 1), away = k < 5 && !still ? r((P - START[k]) / LEN[k], 0.9, 1) : 0, o = inn * (1 - away);
        // Faded, never hidden: all six stay there to be read by a screen reader, in their order.
        if (!o && cap.off) return;
        cap.off = !o;
        parts[k].forEach(function (part, n) {
          O(part, o);
          // Coming up, the lower lines have further to come; going, the upper ones go further.
          T(part, 'translate3d(0,' + px(((1 - out(inn)) * (1 + n * 0.7) - io(away) * (1 + (parts[k].length - 1 - n) * 0.7)) * G.shift) + ',0)');
        });
      });
      var at = Math.max(ci, 0);
      segs.forEach(function (seg, k) {
        T(seg.fill, 'scaleX(' + t[k].toFixed(4) + ')');
        C(seg.node, 'is-on', k === at);
      });
      say(count, (at + 1) + ' of ' + segs.length);
      O(nav, r(q, 0.8, 1));
      V(nav, q > 0.8);

      // Leaving: the stage goes at half the speed of the page, and the next part slides over it.
      T(inner, over ? 'translate3d(0,' + px(over * 0.5) + ',0)' : 'none');
    }

    /* The scroll is followed a little behind, so that a turn of the wheel is a glide and not a jump.
       Nothing runs while the page is still or the section is out of sight. */
    var cur = null, raf = 0, last = 0, seen = false, clock = 0;
    function where(now) {
      if (!flat) return -section.getBoundingClientRect().top;
      // A page that cannot scroll, in a frame as tall as itself: the film plays by itself.
      clock += last ? Math.min(0.05, (now - last) / 1000) : 0;
      return still ? G.unit * (START[0] + 0.5) : (clock * 0.11 % (TOTAL - 0.4)) * G.unit;
    }
    function frame(now) {
      raf = 0;
      if (!G || !seen) return;
      var aim = where(now);
      if (cur === null || still || flat) cur = aim;
      else {
        cur += (aim - cur) * (1 - Math.exp(-(last ? Math.min(0.05, (now - last) / 1000) : 0.016) / 0.085));
        if (Math.abs(aim - cur) < 0.4) cur = aim;
      }
      last = now;
      render(cur);
      if (cur !== aim || (flat && !still)) raf = requestAnimationFrame(frame);
      else last = 0;
    }
    function kick() { if (!raf) raf = requestAnimationFrame(frame); }
    function jump(i) {
      var y = section.getBoundingClientRect().top + window.pageYOffset + (START[i] + (still ? POSTER[i] : i ? 0.17 : 0) * LEN[i]) * G.unit;
      window.scrollTo({ top: Math.round(y), behavior: still ? 'auto' : 'smooth' });
    }

    try { flat = window.self !== window.top && window.innerHeight > 2400; } catch (err) { flat = false; }
    section.classList.toggle('is-flat', flat);
    measure();
    // The heading is as tall as its face makes it: the desk is placed again once the fonts are in.
    if (doc.fonts && doc.fonts.ready) doc.fonts.ready.then(measure);
    if ('ResizeObserver' in window) new ResizeObserver(measure).observe(dive);
    else window.addEventListener('resize', measure);
    window.addEventListener('scroll', kick, { passive: true });
    if ('IntersectionObserver' in window) {
      new IntersectionObserver(function (entries) {
        seen = entries[entries.length - 1].isIntersecting;
        if (seen) { cur = null; last = 0; kick(); }
      }, { rootMargin: '25% 0px' }).observe(section);
    } else {
      seen = true;
      kick();
    }
  })();

  /* --- The map of desktops, shared by the palette and the notch --------------------------------- */
  var MAP = [
    { name: 'Laptop', desktops: [
      { name: 'Guild', slots: [[0, 0, 0.62, 1, 'mail'], [0.62, 0, 0.38, 1, 'calendar']] },
      { name: 'Sietch', slots: [[0, 0, 0.42, 1, 'messages'], [0.42, 0, 0.58, 1, 'notes']] },
      { name: 'Baliset', slots: [[0, 0, 1, 1, 'music']] }
    ] },
    { name: 'Main', desktops: [
      { name: 'Navigator', slots: [[0, 0, 0.58, 1, 'code'], [0.58, 0, 0.42, 0.5, 'safari'], [0.58, 0.5, 0.42, 0.5, 'terminal']] },
      { name: 'Arrakis', slots: [[0, 0, 0.27, 1, 'notes'], [0.27, 0, 0.46, 1, 'safari'], [0.73, 0, 0.27, 1, 'calendar']] },
      { name: 'Everything else', free: true, slots: [] }
    ] },
    { name: 'Right', desktops: [
      { name: 'Caladan', slots: [[0, 0, 1, 0.55, 'calendar'], [0, 0.55, 1, 0.45, 'notes']] }
    ] }
  ];

  function buildMap(host, onPick) {
    var tiles = [];
    MAP.forEach(function (display, d) {
      var row = el('div', 'map-row', '<span class="map-name">' + display.name + '</span>');
      var line = el('div', 'map-tiles');
      display.desktops.forEach(function (desktop, i) {
        var tile = el('div', 'map-tile' + (i === 0 ? ' is-shown' : ''),
          '<div class="map-box' + (desktop.free ? ' free' : '') + '">' + desktop.slots.map(function (s) {
            return '<i style="left:' + s[0] * 100 + '%;top:' + s[1] * 100 + '%;width:' + s[2] * 100 + '%;height:' + s[3] * 100 + '%">' + ico(s[4]) + '</i>';
          }).join('') + '</div><span>' + desktop.name + '</span>');
        tile.setAttribute('data-name', desktop.name);
        if (onPick) tile.addEventListener('click', function () { onPick(d, i, tile); });
        line.appendChild(tile);
        tiles.push({ node: tile, d: d, i: i, name: desktop.name });
      });
      row.appendChild(line);
      host.appendChild(row);
    });
    return {
      tiles: tiles,
      show: function (d, i) { tiles.forEach(function (t) { if (t.d === d) t.node.classList.toggle('is-shown', t.i === i); }); },
      outline: function (name) { tiles.forEach(function (t) { t.node.classList.toggle('is-hit', t.name === name); }); },
      find: function (name) { for (var n = 0; n < tiles.length; n++) if (tiles[n].name === name) return tiles[n]; return null; }
    };
  }

  /* --- The palette: a drawing that takes real typing --------------------------------------------- */
  (function palette() {
    var input = $('pal-input'), list = $('pal-list'), note = $('pal-note'), panel = $('pal');
    if (!input || !list) return;
    var map = buildMap($('pal-map'));
    var HYPER = '⌃⌥⌘';
    var ITEMS = [
      { kind: 'window', icon: 'code', title: 'Fold.swift', sub: 'Code · Navigator', desk: 'Navigator' },
      { kind: 'window', icon: 'safari', title: 'Along the Shield Wall', sub: 'Safari · Arrakis', desk: 'Arrakis' },
      { kind: 'window', icon: 'terminal', title: 'navigator — zsh', sub: 'Terminal · Navigator', desk: 'Navigator' },
      { kind: 'window', icon: 'mail', title: 'Inbox', sub: 'Mail · Guild', desk: 'Guild' },
      { kind: 'window', icon: 'messages', title: 'Sietch', sub: 'Messages · Sietch', desk: 'Sietch' },
      { kind: 'window', icon: 'safari', title: 'Spice harvest up again', sub: 'Safari · Navigator', desk: 'Navigator' },
      { kind: 'window', icon: 'notes', title: 'Deep desert', sub: 'Notes · Arrakis', desk: 'Arrakis' },
      { kind: 'window', icon: 'calendar', title: 'Week', sub: 'Calendar · Caladan', desk: 'Caladan' },
      { kind: 'window', icon: 'music', title: 'Second Moon', sub: 'Music · Baliset · minimised', desk: 'Baliset' },
      { kind: 'app', icon: 'safari', title: 'Safari', sub: 'App · running' },
      { kind: 'app', icon: 'app', title: 'Calculator', sub: 'App' },
      { kind: 'app', icon: 'app', title: 'Preview', sub: 'App' },
      { kind: 'app', icon: 'music', title: 'Music', sub: 'App · running' },
      { kind: 'desktop', icon: 'desktop', title: 'Navigator', sub: 'Desktop · Main', desk: 'Navigator' },
      { kind: 'desktop', icon: 'desktop', title: 'Arrakis', sub: 'Desktop · Main', desk: 'Arrakis' },
      { kind: 'desktop', icon: 'desktop', title: 'Guild', sub: 'Desktop · Laptop', desk: 'Guild' },
      { kind: 'desktop', icon: 'desktop', title: 'Baliset', sub: 'Desktop · Laptop', desk: 'Baliset' },
      { kind: 'desktop', icon: 'desktop', title: 'Caladan', sub: 'Desktop · Right', desk: 'Caladan' },
      { kind: 'desktop', icon: 'desktop', title: 'Everything else', sub: 'Desktop · Main', desk: 'Everything else' },
      { kind: 'scene', icon: 'scene', title: 'Spice run', sub: 'Scene' },
      { kind: 'scene', icon: 'scene', title: 'Storm watch', sub: 'Scene' },
      { kind: 'command', icon: 'command', title: 'Focus a slot, and back', sub: 'Command', keys: HYPER + 'Space' },
      { kind: 'command', icon: 'command', title: 'Put every window back', sub: 'Command', keys: HYPER + 'R' },
      { kind: 'command', icon: 'command', title: 'Next window of a stack', sub: 'Command', keys: HYPER + '⇥' },
      { kind: 'command', icon: 'command', title: 'Open the left drawer', sub: 'Command', keys: HYPER + 'L' },
      { kind: 'command', icon: 'command', title: 'Open the right drawer', sub: 'Command', keys: HYPER + 'D' },
      { kind: 'command', icon: 'command', title: 'Swap two slots', sub: 'Command', keys: '⌃⌥⇧⌘←' },
      { kind: 'command', icon: 'command', title: 'Pause', sub: 'Command', keys: HYPER + 'P' }
    ];
    var ROWS = 6;

    function norm(s) {
      s = s.toLowerCase();
      return s.normalize ? s.normalize('NFD').replace(/[̀-ͯ]/g, '') : s;
    }
    // Best first: the whole name, its start, the start of a word, initials, the middle of a word.
    function score(word, text) {
      var t = norm(text);
      if (t === word) return 0;
      if (t.indexOf(word) === 0) return 1;
      if ((' ' + t).indexOf(' ' + word) >= 0) return 2;
      var initials = t.split(/[\s.]+/).map(function (w) { return w.charAt(0); }).join('');
      if (word.length > 1 && initials.indexOf(word) === 0) return 3;
      if (t.indexOf(word) >= 0) return 4;
      return -1;
    }
    function find(query) {
      var words = norm(query).split(/\s+/).filter(Boolean);
      if (!words.length) return ITEMS.filter(function (it) { return it.kind === 'window'; }).slice(0, ROWS);
      var hits = [];
      ITEMS.forEach(function (it, order) {
        var total = 0;
        for (var i = 0; i < words.length; i++) {
          var a = score(words[i], it.title), b = score(words[i], it.sub);
          if (a < 0 && b < 0) return;
          total += a >= 0 ? a : b + 5;
        }
        hits.push({ it: it, total: total, order: order });
      });
      hits.sort(function (a, b) { return a.total - b.total || a.order - b.order; });
      return hits.slice(0, ROWS).map(function (h) { return h.it; });
    }

    var shown = [], sel = 0;
    function paint() {
      list.innerHTML = shown.length ? shown.map(function (it, i) {
        return '<li' + (i === sel ? ' class="is-sel"' : '') + ' data-i="' + i + '">' + ico(it.icon) +
          '<span class="pal-t"><b>' + it.title + '</b><small>' + it.sub + '</small></span>' +
          (it.keys ? '<span class="pal-k">' + it.keys + '</span>' : '') + '</li>';
      }).join('') : '<li class="pal-none">Nothing by that name.</li>';
      map.outline(shown[sel] ? shown[sel].desk : null);
    }
    function update() {
      shown = find(input.value);
      // With nothing typed the second window is selected: Return goes back to the one before.
      sel = input.value.trim() || shown.length < 2 ? 0 : 1;
      paint();
    }
    function move(by) {
      if (!shown.length) return;
      sel = (sel + by + shown.length) % shown.length;
      paint();
    }

    // Until someone clicks the field, the palette types by itself.
    var SCRIPT = [
      { q: '', note: 'Nothing typed: your windows, front to back, with the one you had before selected.' },
      { q: 'saf', note: 'An app, and its windows on two desktops.' },
      { q: 'arr', note: 'A desktop by its name, and the windows that are on it.' },
      { q: 'foc', note: 'A command, with its shortcut.' },
      { q: 'sto', note: 'A scene: several displays change desktop at once.' }
    ];
    var tl = new Timeline(), auto = !still, at = 0;
    function type(text, i, then) {
      input.value = text.slice(0, i);
      update();
      if (i < text.length) tl.at(150, function () { type(text, i + 1, then); }); else then();
    }
    function play() {
      var line = SCRIPT[at % SCRIPT.length];
      at++;
      type(line.q, 0, function () {
        if (note) note.textContent = line.note;
        tl.at(line.q ? 2600 : 3000, function () { input.value = ''; play(); });
      });
    }
    function takeOver() {
      if (!auto) return;
      auto = false;
      tl.clear();
      input.value = '';
      update();
      if (note) {
        note.setAttribute('aria-live', 'polite');
        note.textContent = 'Type a few letters. ↑ and ↓ move through the list, Return chooses.';
      }
    }

    input.addEventListener('focus', takeOver);
    panel.addEventListener('pointerdown', takeOver);
    input.addEventListener('input', update);
    input.addEventListener('keydown', function (e) {
      if (e.key === 'ArrowDown') { move(1); e.preventDefault(); }
      else if (e.key === 'ArrowUp') { move(-1); e.preventDefault(); }
      else if (e.key === 'Escape') { input.value = ''; update(); }
      else if (e.key === 'Enter' && shown[sel] && note) {
        var it = shown[sel];
        note.textContent = it.kind === 'command' ? 'In Fremspace, Return would run “' + it.title + '”.'
          : it.kind === 'app' ? 'In Fremspace, Return would open ' + it.title + ', or bring it forward.'
          : it.kind === 'scene' ? 'In Fremspace, Return would show the scene ' + it.title + ' on every display.'
          : it.kind === 'desktop' ? 'In Fremspace, Return would show the desktop ' + it.title + '.'
          : 'In Fremspace, Return would give ' + it.title + ' the keyboard, and show its desktop.';
      }
    });
    list.addEventListener('click', function (e) {
      var row = e.target.closest ? e.target.closest('li[data-i]') : null;
      if (row) { sel = +row.getAttribute('data-i'); paint(); }
    });

    update();
    whenVisible(panel, function () { if (auto) { tl.clear(); play(); } }, function () { tl.clear(); });
  })();

  /* --- Scenes: one key, and every display of the desk shows its desktop -------------------------
     Three displays, each with its own desktops. A scene names a desktop for some of them, and may
     put a slot in Focus and open a drawer there. Asking for the scene that is shown leaves it: the
     Focus and the drawer go back as they were, and each display the scene switched goes back to
     the desktop it showed before. Until someone chooses, the scenes are shown and left by
     themselves. */
  (function scenes() {
    var box = $('scene-desk'), chipsBox = $('scene-chips'), status = $('scene-status');
    if (!box || !chipsBox) return;
    var chips = chipsBox.querySelectorAll('button');
    var BAR = 26, GAP = 10;

    // Each display at its own size: the desktop it shows at first, its drawer as [edge, apps,
    // width], and its desktops. A slot is [app, frame, page of Safari, a scene gives it Focus].
    // The desktop a display shows at first is in no scene: leaving a scene goes back to it, and
    // every scene has somewhere to come from.
    var DISPLAYS = [
      { id: 'laptop', name: 'Laptop', kind: 'laptop', w: 540, h: 349, at: 2, drawer: ['right', ['calendar'], 204],
        desktops: [
          { name: 'Guild', tint: 1, slots: [['mail', [0, 0, 0.62, 1], 0, true], ['calendar', [0.62, 0, 0.38, 1]]] },
          { name: 'Sietch', tint: 3, slots: [['messages', [0, 0, 0.42, 1]], ['notes', [0.42, 0, 0.58, 1]]] },
          { name: 'Baliset', tint: 0, slots: [['music', [0, 0, 1, 1]]] }
        ] },
      { id: 'main', name: 'Main', kind: 'main', w: 900, h: 506, at: 2, drawer: ['left', ['messages', 'music'], 340],
        desktops: [
          { name: 'Navigator', tint: 0, slots: [['code', [0, 0, 0.58, 1], 0, true], ['safari', [0.58, 0, 0.42, 0.5]], ['terminal', [0.58, 0.5, 0.42, 0.5]]] },
          { name: 'Arrakis', tint: 1, slots: [['notes', [0, 0, 0.27, 1]], ['safari', [0.27, 0, 0.46, 1], 1, true], ['calendar', [0.73, 0, 0.27, 1]]] },
          // A desktop without a layout: its windows lie where they were left.
          { name: 'Everything else', tint: 3, free: true, slots: [['safari', [0.07, 0.05, 0.56, 0.84]], ['messages', [0.55, 0.22, 0.32, 0.7]]] }
        ] },
      // Turned upright: its two slots are one above the other, and its menu bar has room for less.
      { id: 'right', name: 'Right', kind: 'main', w: 400, h: 620, dk: 30, menus: 2, at: 0, drawer: ['right', ['notes'], 216],
        desktops: [
          { name: 'Caladan', tint: 2, slots: [['calendar', [0, 0, 1, 0.55]], ['notes', [0, 0.55, 1, 0.45]]] },
          { name: 'Harvester', tint: 3, slots: [['safari', [0, 0, 1, 0.56], 2], ['terminal', [0, 0.56, 1, 0.44]]] },
          { name: 'Windtrap', tint: 0, slots: [['mail', [0, 0, 1, 0.56]], ['music', [0, 0.56, 1, 0.44]]] }
        ] }
    ];
    // A scene: the desktop of each display it names, the display where it gives Focus, the one
    // whose drawer it opens, and what it did, in words.
    var SCENES = [
      { name: 'Spice run', show: { laptop: 0, main: 0, right: 1 }, focus: 'main', drawer: 'right',
        says: 'Spice run: three desktops, Code in Focus on Main, the drawer of Right open.' },
      { name: 'Storm watch', show: { laptop: 1, main: 1, right: 2 }, focus: 'main', drawer: 'laptop',
        says: 'Storm watch: three desktops, Safari in Focus on Main, the drawer of the Laptop open.' },
      { name: 'Council', show: { laptop: 0, main: 0 }, focus: 'laptop', drawer: 'main',
        says: 'Council: Mail in Focus on the Laptop, the drawer of Main open. It does not name Right, which keeps what it shows.' }
    ];
    // Where each display stands, as [x, y, scale]: side by side on a wide page, Main above the two
    // others on a narrow one.
    var PLACES = {
      wide: { w: 1850, h: 650, at: { laptop: [74, 263, 0.86], main: [655, 33, 0.9], right: [1535, 62, 0.72] } },
      narrow: { w: 720, h: 950, at: { main: [27, 18, 0.74], laptop: [50, 680, 0.58], right: [470, 533, 0.5] } }
    };

    var view = fit(box, PLACES.wide.w, PLACES.wide.h), mode = '';
    var desk = DISPLAYS.map(function (d) {
      var made = makeDisplay(d.kind, '', 'safari mail messages calendar notes music code terminal');
      var dock = Math.round((d.dk || 36) * 1.67);
      function at(f) { return slotRect(d.w, d.h, f, BAR, GAP, dock); }
      if (d.dk) made.screen.style.setProperty('--dk', d.dk + 'px');
      if (d.menus) each(made.screen.querySelectorAll('.mbar > span'), function (m, i) { if (i >= d.menus) m.parentNode.removeChild(m); });
      made.node.style.width = d.w + 'px';
      made.node.style.height = d.h + 'px';

      var rows = deck(made.screen, d.desktops.map(function (t) { return t.tint; })), room = d.h - BAR - dock;
      var desktops = d.desktops.map(function (t, i) {
        var page = rows.pages[i], lead = null;
        var wins = t.slots.map(function (s) {
          var f = s[1], rect = t.free ? { x: f[0] * d.w, y: BAR + f[1] * room, w: f[2] * d.w, h: f[3] * room } : at(f);
          if (s[3]) return (lead = add(page, s[0], rect, s[2]));
          return { node: put(page, s[0], rect, s[2]), app: s[0] };
        });
        // The slot a scene puts in Focus has the keyboard; without one, the first slot has it, or
        // the window on top where there are no slots.
        var front = lead || wins[t.free ? wins.length - 1 : 0];
        key(front.node);
        return { name: t.name, page: page, lead: lead, front: front, timer: 0 };
      });

      var edge = d.drawer[0], parked = d.drawer[1], width = d.drawer[2];
      var drawer = el('div', 'drawer ' + edge), tall = (d.h - BAR - dock - GAP * (parked.length + 1)) / parked.length;
      drawer.style.width = width + 'px';
      drawer.style.bottom = dock + 'px';
      parked.forEach(function (app, i) {
        var w = makeWin(app);
        if (!i) w.classList.add('is-key');
        frame(w, { x: GAP, y: GAP + i * (tall + GAP), w: width - GAP * 2, h: tall });
        drawer.appendChild(w);
      });
      made.screen.appendChild(drawer);

      var say = banner(made.screen.appendChild(el('div', d.kind === 'laptop' ? 'ndrop' : 'pill')));
      var tag = made.node.appendChild(el('span', 'tag', '<b>' + d.name + '</b><span></span>'));
      view.inner.appendChild(made.node);
      rows.show(d.at);
      return { id: d.id, node: made.node, rows: rows, desktops: desktops, at: d.at, full: at([0, 0, 1, 1]), drawer: drawer,
        say: say, tag: tag.lastChild, app: made.screen.querySelector('.mbar b') };
    });
    // Under a display, the desktop it shows; in its menu bar, the app in front there.
    function face(d) {
      var t = d.desktops[d.at];
      d.tag.textContent = t.name;
      d.app.textContent = NAMES[t.front.app];
    }
    desk.forEach(face);

    function arrange() {
      var next = box.clientWidth < 820 ? 'narrow' : 'wide', place = PLACES[next];
      // The tags keep their size on the page: they are told how much the drawing is reduced.
      if (box.clientWidth) box.style.setProperty('--inv', (place.w / box.clientWidth).toFixed(3));
      if (next === mode) return;
      mode = next;
      view.size(place.w, place.h);
      desk.forEach(function (d) {
        var at = place.at[d.id];
        d.node.style.left = at[0] + 'px';
        d.node.style.top = at[1] + 'px';
        d.node.style.transform = 'scale(' + at[2] + ')';
        d.node.style.setProperty('--s', at[2]);
      });
    }
    arrange();
    if ('ResizeObserver' in window) new ResizeObserver(arrange).observe(box);
    else window.addEventListener('resize', arrange);

    var tl = new Timeline();
    function later(ms, fn) { if (still || !ms) fn(); else tl.at(ms, fn); }

    // Focus on a desktop: its slot takes it all and the other windows are gone, or all is back.
    function focus(d, t, on, now) {
      if (!t.lead) return;
      clearTimeout(t.timer);
      t.page.classList.toggle('is-focus', on);
      if (on) t.lead.node.classList.add('is-top');
      if (now) t.lead.m.set(on ? d.full : t.lead.rect);
      else t.lead.m.go(on ? d.full : t.lead.rect, { k: 110, c: 19 });
      // The window stays in front until it is back in its slot.
      if (!on) t.timer = setTimeout(function () { t.lead.node.classList.remove('is-top'); }, now || still ? 0 : 900);
    }
    // One display goes to its desktop; then the slot takes it, and the drawer comes in.
    function turn(d, to, lead, open, quiet) {
      var from = d.at, moved = to !== from;
      d.desktops.forEach(function (t, i) { if (i !== to && i !== from) focus(d, t, false, true); });
      if (moved) {
        d.at = to;
        d.rows.show(to);
        face(d);
        if (!quiet) d.say(d.desktops[to].name, to, d.desktops.length);
        // The desktop it leaves is put back at rest once it is out of sight.
        later(900, function () { focus(d, d.desktops[from], false, true); });
      }
      if (!open) d.drawer.classList.remove('is-open');
      later(moved ? 600 : 0, function () {
        focus(d, d.desktops[to], lead);
        d.drawer.classList.toggle('is-open', open);
      });
    }
    // Where each display the scene shown switched came from. A display it found on its desktop
    // already, or does not name, is not in it.
    var cameFrom = {};
    // The desk as a scene wants it, one display after the other: that is how Fremspace asks macOS
    // for them. The scene that was shown gives back its Focus and its drawer, and the displays do
    // not go back first: they go from where they are.
    function enter(sc, quiet) {
      tl.clear();
      cameFrom = {};
      desk.forEach(function (d, n) {
        var to = sc.show[d.id] != null ? sc.show[d.id] : d.at;
        if (to !== d.at) cameFrom[d.id] = d.at;
        later(n * 300, function () { turn(d, to, sc.focus === d.id, sc.drawer === d.id, quiet); });
      });
    }
    // Leaving: the Focus and the drawer go back at once, then each display the scene switched goes
    // back to the desktop it showed before, one after the other, like they came.
    function leave() {
      var back = cameFrom, n = 0;
      tl.clear();
      cameFrom = {};
      desk.forEach(function (d) {
        turn(d, d.at, false, false);
        if (back[d.id] != null) later(550 + 300 * n++, function () { turn(d, back[d.id], false, false); });
      });
    }

    var shown = -1, next = 0, auto = new Timeline(), autoOn = !still, visible = false, over = false;
    function show(i, quiet) {
      var leaving = i === shown;
      shown = leaving ? -1 : i;
      each(chips, function (c, j) { c.setAttribute('aria-pressed', j === shown ? 'true' : 'false'); });
      status.textContent = leaving ? 'You left ' + SCENES[i].name + ': the Focus is given back, the drawer is closed, and each display it switched shows the desktop it showed before.' : SCENES[i].says;
      if (leaving) leave(); else enter(SCENES[i], quiet);
    }
    // By itself: the keys of the scene go down, then the desk answers. Shown, it is left and the
    // desk goes back to where it was; left, the next one is shown.
    function step() {
      var i = shown >= 0 ? shown : next;
      if (shown < 0) next = (next + 1) % SCENES.length;
      press(chips[i], function () { if (autoOn && !over) show(i); });
      auto.at(shown >= 0 ? 3600 : 5400, step);
    }
    function start() { auto.clear(); if (autoOn && visible && !over) auto.at(shown >= 0 ? 2600 : 1200, step); }
    // From the first choice on, what the scene did is said aloud as well; not while it plays alone.
    function takeOver() {
      status.setAttribute('aria-live', 'polite');
      autoOn = false;
      auto.clear();
    }

    each(chips, function (chip, i) {
      // A reader's click is the key press: the desk answers at once.
      chip.addEventListener('click', function () { takeOver(); press(chip); show(i); });
      chip.addEventListener('focus', function () { if (chip.matches(':focus-visible')) takeOver(); });
    });
    // Nothing changes under a pointer that is about to choose.
    chipsBox.addEventListener('pointerenter', function (e) { if (e.pointerType === 'mouse') { over = true; auto.clear(); } });
    chipsBox.addEventListener('pointerleave', function () { over = false; start(); });
    // The real keys work too, while the desk is on screen.
    doc.addEventListener('keydown', function (e) {
      if (!visible || e.repeat || !(e.ctrlKey && e.altKey && e.metaKey) || !/^Digit[1-3]$/.test(e.code || '')) return;
      e.preventDefault();
      takeOver();
      press(chips[+e.code.slice(5) - 1]);
      show(+e.code.slice(5) - 1);
    });

    // Without motion nothing plays: the first scene is there to look at, and the chips still answer.
    if (still) show(0, true);
    whenVisible(box, function () { visible = true; start(); }, function () { visible = false; auto.clear(); });
  })();

  /* --- The notch of a MacBook, close up ---------------------------------------------------------- */
  (function lid() {
    var host = $('lid');
    if (!host) return;
    var crop = host.parentNode, LW = 1100;
    function size() { crop.style.setProperty('--ls', clamp(crop.clientWidth / 1180, 0.62, 1.2).toFixed(4)); }
    size();
    if ('ResizeObserver' in window) new ResizeObserver(size).observe(crop);
    else window.addEventListener('resize', size);

    var names = MAP[0].desktops.map(function (d) { return d.name; });
    // The front app of each desktop, for the menu bar.
    var fronts = ['Mail', 'Messages', 'Music'];
    host.innerHTML =
      '<div class="lid-screen">' +
        '<div class="lid-pages"><div class="lid-page"></div><div class="lid-page"></div><div class="lid-page"></div></div>' +
        '<div class="mbar">' + menubar(fronts[0]) + '</div>' +
        '<div class="lid-drop"><span></span><em></em></div>' +
        '<div class="lid-map"></div>' +
        '<div class="lid-notch"></div>' +
        '<svg class="lid-cursor" viewBox="0 0 20 24" aria-hidden="true"><path d="M2 1.500v17l4.600-4.200 3 7 2.800-1.200-3-6.900H16z" fill="#fff" stroke="#000" stroke-width="1.200" stroke-linejoin="round"/></svg>' +
      '</div>';
    var pages = host.querySelector('.lid-pages'), drop = host.querySelector('.lid-drop'), mapNode = host.querySelector('.lid-map');
    var notch = host.querySelector('.lid-notch'), cursor = host.querySelector('.lid-cursor'), appName = host.querySelector('.mbar b');
    var SW = LW - 28, TOP = 36 + 10, G = 10;
    [[['mail', 0, 0.62], ['calendar', 0.62, 0.38]], [['messages', 0, 0.42], ['notes', 0.42, 0.58]], [['music', 0, 1]]].forEach(function (apps, p) {
      apps.forEach(function (a, i) {
        var w = makeWin(a[0]);
        if (i === 0) w.classList.add('is-key');
        frame(w, { x: a[1] * SW + (a[1] ? G / 2 : G), y: TOP, w: a[2] * SW - (a[2] < 1 ? G * 1.5 : G * 2), h: 480 });
        pages.children[p].appendChild(w);
      });
    });

    var shown = 0, tl = new Timeline(), nameTimer = 0, closeTimer = 0, auto = true;
    var map = buildMap(mapNode, function (d, i) {
      map.show(d, i);
      if (d === 0) go(i, true);
      closeMap(true);
    });

    function go(i, quiet) {
      if (i === shown) return;
      shown = i;
      pages.style.transform = 'translateX(' + (-i * 100) + '%)';
      appName.textContent = fronts[i];
      map.show(0, i);
      if (!quiet) speak();
    }
    // The name hangs for a moment, with one dot per desktop of the display.
    function speak() {
      drop.firstChild.textContent = names[shown];
      drop.lastChild.innerHTML = names.map(function (n, i) { return '<u' + (i === shown ? ' class="on"' : '') + '></u>'; }).join('');
      drop.classList.add('is-on');
      clearTimeout(nameTimer);
      nameTimer = setTimeout(function () { drop.classList.remove('is-on'); }, 1500);
    }
    function openMap() { clearTimeout(closeTimer); drop.classList.remove('is-on'); host.classList.add('map-open'); }
    function closeMap(now) {
      clearTimeout(closeTimer);
      closeTimer = setTimeout(function () { host.classList.remove('map-open'); map.outline(null); }, now ? 0 : 250);
    }
    function point(x, y, on) {
      cursor.style.transform = 'translate(' + x + 'px,' + y + 'px)';
      cursor.classList.toggle('is-on', on !== false);
    }

    function loop() {
      point(760, 330, false);
      tl.at(1300, function () { go(1); });
      tl.at(3900, function () { go(2); });
      tl.at(6300, function () { point(760, 330); });
      tl.at(6500, function () { point(LW / 2 - 14 + 4, 10); });
      tl.at(7400, openMap);
      tl.at(8300, function () {
        var t = map.find(names[0]).node.querySelector('.map-box');
        var a = t.getBoundingClientRect(), b = host.getBoundingClientRect(), s = b.width / LW || 1;
        point((a.left - b.left + a.width / 2) / s - 14, (a.top - b.top + a.height / 2) / s - 14);
        map.outline(names[0]);
      });
      tl.at(9500, function () { go(0, true); closeMap(true); });
      tl.at(10100, function () { point(760, 330, false); });
      tl.at(11400, loop);
    }
    function start() { tl.clear(); if (auto && !still) loop(); }

    // A reader's own pointer takes the notch over.
    notch.addEventListener('pointerenter', function () { auto = false; tl.clear(); point(0, 0, false); openMap(); });
    notch.addEventListener('pointerleave', function () { closeMap(); });
    mapNode.addEventListener('pointerenter', function () { if (!auto) clearTimeout(closeTimer); });
    mapNode.addEventListener('pointerleave', function () { if (!auto) closeMap(); });
    mapNode.addEventListener('pointerover', function (e) {
      if (auto) return;
      var tile = e.target.closest ? e.target.closest('.map-tile') : null;
      map.outline(tile ? tile.getAttribute('data-name') : null);
    });
    host.addEventListener('pointerleave', function () { if (!auto) { auto = true; tl.at(1800, start); } });

    if (still) { speak(); clearTimeout(nameTimer); }
    whenVisible(host, start, function () { tl.clear(); });
  })();

  /* --- The keyboard: a shortcut lights its keys -------------------------------------------------- */
  (function keyboard() {
    var kb = $('kb'), cuts = $('cuts'), hyper = $('hyper');
    if (!kb || !cuts) return;
    // [id, label, width in key units]
    var ROWS = [
      [['`', '`'], ['1', '1'], ['2', '2'], ['3', '3'], ['4', '4'], ['5', '5'], ['6', '6'], ['7', '7'], ['8', '8'], ['9', '9'], ['0', '0'], ['-', '-'], ['=', '='], ['delete', '⌫', 1.5]],
      [['tab', '⇥', 1.5], ['q', 'Q'], ['w', 'W'], ['e', 'E'], ['r', 'R'], ['t', 'T'], ['y', 'Y'], ['u', 'U'], ['i', 'I'], ['o', 'O'], ['p', 'P'], ['[', '['], [']', ']'], ['\\', '\\']],
      [['caps', '⇪', 1.75], ['a', 'A'], ['s', 'S'], ['d', 'D'], ['f', 'F'], ['g', 'G'], ['h', 'H'], ['j', 'J'], ['k', 'K'], ['l', 'L'], [';', ';'], ['\'', '\''], ['return', '↩', 1.75]],
      [['shift', '⇧', 2.25], ['z', 'Z'], ['x', 'X'], ['c', 'C'], ['v', 'V'], ['b', 'B'], ['n', 'N'], ['m', 'M'], [',', ','], ['.', '.'], ['/', '/'], ['shift2', '⇧', 2.25]],
      [['fn', 'fn'], ['ctrl', '⌃'], ['opt', '⌥'], ['cmd', '⌘', 1.25], ['space', '', 5], ['cmd2', '⌘', 1.25], ['opt2', '⌥'], ['left', '←'], ['updown', ''], ['right', '→']]
    ];
    var LABEL = { space: 'Space', tab: '⇥', left: '←', right: '→', up: '↑', down: '↓' };
    var keys = {};
    ROWS.forEach(function (row) {
      var line = el('div', 'kb-row');
      row.forEach(function (k) {
        var key = el('span', 'key');
        key.style.flexGrow = k[2] || 1;
        if (k[0] === 'updown') {
          key.className = 'key pair';
          ['up', 'down'].forEach(function (id) { keys[id] = key.appendChild(el('span', 'key', LABEL[id])); });
        } else {
          key.textContent = k[1];
          keys[k[0]] = key;
        }
        line.appendChild(key);
      });
      kb.appendChild(line);
    });

    var buttons = cuts.querySelectorAll('button'), on = 0, isHyper = false;
    function mods(button) {
      var m = isHyper ? ['caps'] : ['ctrl', 'opt', 'cmd'];
      return button.hasAttribute('data-shift') ? m.concat('shift') : m;
    }
    function label(button) {
      var ids = button.getAttribute('data-keys').split(' ');
      var m = (isHyper ? '⇪' : '⌃⌥') + (button.hasAttribute('data-shift') ? '⇧' : '') + (isHyper ? '' : '⌘');
      var tail = ids.length === 4 && ids[0] === '1' ? ['1', '…', '4'] : ids.map(function (id) { return LABEL[id] || id.toUpperCase(); });
      return m.split('').concat(tail).map(function (c) { return c === '…' ? '<i>…</i>' : '<kbd>' + c + '</kbd>'; }).join('');
    }
    function write() {
      each(buttons, function (b) {
        var span = b.querySelector('.cut-keys') || b.appendChild(el('span', 'cut-keys'));
        span.innerHTML = label(b);
      });
    }
    function select(i) {
      on = i;
      var b = buttons[i], lit = mods(b).concat(b.getAttribute('data-keys').split(' '));
      for (var id in keys) keys[id].classList.toggle('is-lit', lit.indexOf(id) >= 0);
      each(buttons, function (x, j) { x.classList.toggle('is-on', j === i); x.setAttribute('aria-pressed', j === i ? 'true' : 'false'); });
    }

    var tl = new Timeline(), auto = !still;
    function cycle() { tl.at(2100, function () { select((on + 1) % buttons.length); cycle(); }); }
    function stop() { auto = false; tl.clear(); }
    each(buttons, function (b, i) {
      b.addEventListener('click', function () { stop(); select(i); });
      b.addEventListener('pointerenter', function (e) { if (e.pointerType === 'mouse') { stop(); select(i); } });
      b.addEventListener('focus', function () { if (b.matches(':focus-visible')) { stop(); select(i); } });
    });
    if (hyper) hyper.addEventListener('click', function () {
      isHyper = !isHyper;
      hyper.setAttribute('aria-checked', isHyper ? 'true' : 'false');
      kb.classList.toggle('is-hyper', isHyper);
      write(); select(on);
    });

    // The keyboard also answers the reader's own keys, while it is on screen.
    var CODES = { Space: 'space', Tab: 'tab', CapsLock: 'caps', ShiftLeft: 'shift', ShiftRight: 'shift2', ControlLeft: 'ctrl', ControlRight: 'ctrl', AltLeft: 'opt', AltRight: 'opt2', MetaLeft: 'cmd', MetaRight: 'cmd2', ArrowLeft: 'left', ArrowRight: 'right', ArrowUp: 'up', ArrowDown: 'down', Backspace: 'delete', Enter: 'return', Backquote: '`', Minus: '-', Equal: '=', BracketLeft: '[', BracketRight: ']', Backslash: '\\', Semicolon: ';', Quote: '\'', Comma: ',', Period: '.', Slash: '/' };
    function keyOf(e) {
      var c = e.code || '';
      if (CODES[c]) return keys[CODES[c]];
      if (c.indexOf('Key') === 0) return keys[c.slice(3).toLowerCase()];
      if (c.indexOf('Digit') === 0) return keys[c.slice(5)];
      return null;
    }
    var live = false;
    function clearPressed() { for (var id in keys) keys[id].classList.remove('is-pressed'); }
    doc.addEventListener('keydown', function (e) { var k = live && keyOf(e); if (k) k.classList.add('is-pressed'); });
    doc.addEventListener('keyup', function (e) {
      var k = keyOf(e);
      // macOS sends no keyup for the keys held with Command: releasing it releases them all.
      if (e.key === 'Meta') clearPressed(); else if (k) k.classList.remove('is-pressed');
    });
    window.addEventListener('blur', clearPressed);

    write();
    select(0);
    whenVisible(kb, function () { live = true; if (auto) { tl.clear(); cycle(); } }, function () { live = false; tl.clear(); clearPressed(); });
  })();

  /* --- The page's own notch ----------------------------------------------------------------------- */
  (function pageNotch() {
    var notch = $('notch');
    if (!notch) return;
    var pill = notch.querySelector('.notch-pill'), dots = notch.querySelector('.notch-dots');
    var name = notch.querySelector('.notch-drop span'), links = notch.querySelectorAll('.notch-map a');
    var parts = doc.querySelectorAll('[data-desktop]');
    var current = -1, timer = 0;
    each(parts, function () { dots.appendChild(el('i')); });

    var canHover = !!(window.matchMedia && window.matchMedia('(hover: hover)').matches);
    function isOpen() { return notch.classList.contains('is-open') || (canHover && notch.matches(':hover')) || notch.matches(':focus-within'); }
    function show(i) {
      if (i === current) return;
      var first = current < 0;
      current = i;
      each(dots.children, function (d, j) { d.classList.toggle('on', j === i); });
      each(links, function (a, j) { if (j === i) a.setAttribute('aria-current', 'true'); else a.removeAttribute('aria-current'); });
      // Like the app: nothing is said for the part you arrive on, nor while the map is open.
      if (first || isOpen()) return;
      name.textContent = parts[i].getAttribute('data-desktop');
      notch.classList.add('is-speaking');
      clearTimeout(timer);
      timer = setTimeout(function () { notch.classList.remove('is-speaking'); }, 1400);
    }
    if ('IntersectionObserver' in window) {
      var io = new IntersectionObserver(function (entries) {
        entries.forEach(function (entry) {
          if (entry.isIntersecting) show(Array.prototype.indexOf.call(parts, entry.target));
        });
      }, { rootMargin: '-45% 0px -55% 0px' });
      each(parts, function (p) { io.observe(p); });
    }
    show(0);

    function open(flag) {
      notch.classList.toggle('is-open', flag);
      pill.setAttribute('aria-expanded', flag ? 'true' : 'false');
    }
    pill.addEventListener('click', function () {
      var closing = notch.classList.contains('is-open');
      notch.classList.remove('is-shut');
      open(!closing);
      // The button keeps the focus after a click, and focus alone holds the map open.
      if (closing) pill.blur();
    });
    each(links, function (a) {
      a.addEventListener('click', function () {
        // The map closes at once after a click, and stays shut until the pointer has left.
        open(false);
        notch.classList.add('is-shut');
        a.blur();
      });
    });
    notch.addEventListener('pointerleave', function () { notch.classList.remove('is-shut'); });
    doc.addEventListener('click', function (e) {
      if (notch.contains(e.target)) return;
      open(false);
      if (notch.contains(doc.activeElement)) doc.activeElement.blur();
    });
    doc.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && (notch.classList.contains('is-open') || notch.contains(doc.activeElement))) {
        open(false);
        if (notch.contains(doc.activeElement)) doc.activeElement.blur();
      }
    });
  })();

})();
