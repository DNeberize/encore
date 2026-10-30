// Runs Encore/Resources/encore.js inside a simulated YouTube page and checks
// the playback rules: background resume, calls, headphones, lock-screen
// commands, autoplay, ad removal and visibility spoofing.
//
//   node tests/encore.test.js

'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const SCRIPT = fs.readFileSync(path.join(__dirname, '..', 'Encore', 'Resources', 'encore.js'), 'utf8');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------------------------------------------------------------------------
// Minimal page environment
// ---------------------------------------------------------------------------

function makePage({ nativeMediaSession = false, role = 'browse' } = {}) {
  const timers = [];
  const posted = [];
  const ctx = vm.createContext({
    console, URL, URLSearchParams,
    setTimeout: (f, ms) => { const t = setTimeout(f, ms); timers.push(t); return t; },
    clearTimeout,
    setInterval: (f, ms) => { const t = setInterval(f, ms); timers.push(t); return t; },
    clearInterval,
    queueMicrotask,
  });

  vm.runInContext(`
    var window = globalThis;
    var top = globalThis;
    var location = { hostname: 'm.youtube.com', href: 'https://m.youtube.com/watch?v=abc123' };

    class Listeners {
      constructor() { this.capture = {}; this.bubble = {}; }
      addEventListener(type, fn, capture) {
        const bag = capture ? this.capture : this.bubble;
        (bag[type] = bag[type] || []).push(fn);
      }
      removeEventListener() {}
    }

    // Dispatch along window -> document -> target (capture), then bubble.
    function dispatch(target, type) {
      let stopped = false;
      const ev = { type, target, isTrusted: true, stopImmediatePropagation() { stopped = true; }, stopPropagation() { stopped = true; } };
      const path = [window, document];
      for (const node of path) {
        for (const fn of (node.capture[type] || [])) { if (stopped) return ev; fn(ev); }
      }
      if (target !== document && target.capture) {
        for (const fn of (target.capture[type] || [])) { if (stopped) return ev; fn(ev); }
      }
      if (target === document) {
        for (const fn of (document.bubble[type] || [])) { if (stopped) return ev; fn(ev); }
      }
      return ev;
    }
    window.capture = {}; window.bubble = {};
    window.addEventListener = Listeners.prototype.addEventListener;
    window.removeEventListener = function () {};

    class Document extends Listeners {}
    Object.defineProperty(Document.prototype, 'hidden', { configurable: true, get() { return window.__reallyHidden; } });
    Object.defineProperty(Document.prototype, 'visibilityState', { configurable: true, get() { return window.__reallyHidden ? 'hidden' : 'visible'; } });
    window.__reallyHidden = false;

    class HTMLMediaElement extends Listeners {
      constructor() {
        super();
        this.paused = true; this.ended = false; this.muted = false;
        this.currentTime = 0; this.duration = 200; this.playbackRate = 1;
        this.playCalls = 0;
      }
      play() {
        this.playCalls++;
        if (window.__blockPlay) return Promise.reject(new Error('NotAllowedError'));
        const wasPaused = this.paused;
        this.paused = false; this.ended = false;
        if (wasPaused) setTimeout(() => { dispatch(this, 'play'); dispatch(this, 'playing'); }, 0);
        return Promise.resolve();
      }
      pause() {
        if (this.paused) return;
        this.paused = true;
        setTimeout(() => dispatch(this, 'pause'), 0);
      }
      finish() {  // playback reached the end
        this.currentTime = this.duration; this.paused = true; this.ended = true;
        setTimeout(() => { dispatch(this, 'pause'); dispatch(this, 'ended'); }, 0);
      }
    }

    const classes = new Set(['html5-video-player']);
    const video = new HTMLMediaElement();
    const playerEl = {
      classList: { contains: (c) => classes.has(c), add: (c) => classes.add(c), remove: (c) => classes.delete(c) },
      querySelector: (s) => s === 'video' ? video : null,
    };
    const styles = [];
    var document = new Document();
    document.title = 'Never Gonna Give You Up - YouTube';
    document.documentElement = { appendChild: (s) => styles.push(s) };
    document.head = null;
    document.createElement = () => ({ textContent: '' });
    document.querySelector = (s) => s === '.html5-video-player' ? playerEl : null;
    document.querySelectorAll = () => [];
    document.getElementById = () => null;

    class Navigator {}
    var navigator = new Navigator();
    class Response {
      constructor(body, url) { this.body = body; this.url = url || ''; }
      text() { return Promise.resolve(this.body); }
      json() { return Promise.resolve(JSON.parse(this.body)); }
    }
    class XMLHttpRequest {
      open(method, url) { this._url = url; }
      setBody(b) { this._body = b; }
    }
    Object.defineProperty(XMLHttpRequest.prototype, 'responseText', { configurable: true, get() { return this._body; } });
    Object.defineProperty(XMLHttpRequest.prototype, 'response', { configurable: true, get() { return this._body; } });
    class Node {
      appendChild(n) { return n; }
      insertBefore(n) { return n; }
    }
    var history = {
      backs: 0, pushed: [],
      pushState(s, t, url) { this.pushed.push(url); },
      replaceState() {},
      back() { this.backs++; },
    };
    window.fetch = function fetch() {};
    window.Request = function Request() {};

    window.webkit = { messageHandlers: { encore: { postMessage: (m) => window.__posted.push(m) } } };
    window.__posted = [];
    window.__encoreAdblock = true;
    window.__encoreRole = ${JSON.stringify(role)};
    window.__test = { video, classes, styles, dispatch, HTMLMediaElement, Response, XMLHttpRequest, Node };
  `, ctx);

  if (nativeMediaSession) {
    vm.runInContext(`
      class MediaSession {
        constructor() { this._meta = null; this.native = {}; }
        setActionHandler(a, h) { this.native[a] = h; }
      }
      Object.defineProperty(MediaSession.prototype, 'metadata', {
        configurable: true, get() { return this._meta; }, set(v) { this._meta = v; }
      });
      window.MediaSession = MediaSession;
      window.MediaMetadata = function (i) { Object.assign(this, i); };
      const ms = new MediaSession();
      Object.defineProperty(Navigator.prototype, 'mediaSession', { configurable: true, get() { return ms; } });
    `, ctx);
  }

  vm.runInContext(SCRIPT, ctx);
  const t = ctx.__test;
  return {
    ctx, video: t.video, classes: t.classes, styles: t.styles,
    api: ctx.__encore,
    posted: () => ctx.__posted,
    last: () => ctx.__posted[ctx.__posted.length - 1],
    run: (code) => vm.runInContext(code, ctx),
    // What iOS/WebKit does on its own (not a user action).
    systemPause: () => t.video.pause(),
    dispose: () => timers.forEach((x) => { clearTimeout(x); clearInterval(x); }),
  };
}

// ---------------------------------------------------------------------------
// Tiny test runner
// ---------------------------------------------------------------------------

const results = [];
async function test(name, fn) {
  const pages = [];
  const page = (opts) => { const p = makePage(opts); pages.push(p); return p; };
  try {
    await fn(page);
    results.push([true, name]);
  } catch (e) {
    results.push([false, name, e.message]);
  } finally {
    pages.forEach((p) => p.dispose());
  }
}
function expect(cond, msg) { if (!cond) throw new Error(msg); }

// Starts playback the way a user tap would, and lets events settle.
async function startPlaying(p) {
  p.video.play();
  await sleep(100);
  expect(!p.video.paused, 'setup: video should be playing');
}

// ---------------------------------------------------------------------------
// Scenarios
// ---------------------------------------------------------------------------

(async () => {
  await test('reports playing state, title and artwork to the app', async (page) => {
    const p = page();
    await startPlaying(p);
    const m = p.last();
    expect(m && m.type === 'media' && m.playing === true, 'expected a playing report');
    expect(m.title === 'Never Gonna Give You Up', 'title cleaned: ' + m.title);
    expect(m.artwork === 'https://i.ytimg.com/vi/abc123/hqdefault.jpg', 'artwork: ' + m.artwork);
    expect(m.duration === 200, 'duration reported');
  });

  await test('page always looks visible; visibilitychange never reaches YouTube', async (page) => {
    const p = page();
    p.run('window.__reallyHidden = true');
    expect(p.run('document.hidden') === false, 'document.hidden should be false');
    expect(p.run('document.visibilityState') === 'visible', 'visibilityState should be visible');
    p.run('window.__ytSaw = 0; document.addEventListener("visibilitychange", () => window.__ytSaw++)');
    p.run('window.__test.dispatch(document, "visibilitychange")');
    expect(p.run('window.__ytSaw') === 0, 'YouTube listener should not fire');
  });

  await test('going to Home Screen / locking: iOS pause is undone automatically', async (page) => {
    const p = page();
    await startPlaying(p);
    p.api.setBackground(true);
    p.systemPause();
    await sleep(50);
    expect(p.video.paused, 'paused right after iOS pause');
    await sleep(700);
    expect(!p.video.paused, 'should be playing again in the background');
  });

  await test('Home Screen / lock: iOS pauses BEFORE the app reports background -> resumes', async (page) => {
    const p = page();
    await startPlaying(p);
    p.api.prepareBackground();               // will resign active
    p.systemPause();                          // WebKit pauses the video
    await sleep(80);
    p.api.setBackground(true);               // did enter background
    await sleep(400);
    expect(!p.video.paused, 'should be playing again');
    expect(p.posted().every((m) => m.event !== 'pause'), 'lock screen never shown as paused');
  });

  await test('no "resign active" notice at all, pause then background -> resumes', async (page) => {
    const p = page();
    await startPlaying(p);
    p.systemPause();
    await sleep(120);
    p.api.setBackground(true);
    await sleep(400);
    expect(!p.video.paused, 'should be playing again');
  });

  await test('iOS keeps re-pausing / first play() refused -> retries win', async (page) => {
    const p = page();
    await startPlaying(p);
    p.api.prepareBackground();
    p.run('window.__blockPlay = true');       // WebKit refuses the first attempts
    p.systemPause();
    p.api.setBackground(true);
    await sleep(400);
    expect(p.video.paused, 'still paused while refused');
    p.run('window.__blockPlay = false');
    p.api.kick();                              // the app's retry
    await sleep(80);
    expect(!p.video.paused, 'retry resumes');
    p.systemPause();                           // paused again later
    await sleep(400);
    expect(!p.video.paused, 'resumes again');
  });

  await test('Control Center pulled down and back: keeps playing, later pause respected', async (page) => {
    const p = page();
    await startPlaying(p);
    p.api.prepareBackground();
    p.api.setBackground(false);               // became active again
    await sleep(50);
    expect(!p.video.paused, 'still playing');
    p.video.pause();                          // user taps pause in YouTube
    await sleep(400);
    expect(p.video.paused, 'user pause respected');
  });

  await test('LOCK SCREEN pause (iOS controls) in background: stays paused, never auto-resumed', async (page) => {
    const p = page({ nativeMediaSession: true });
    p.run('window.__ytPause = 0; navigator.mediaSession.setActionHandler("pause", () => { window.__ytPause++; window.__test.video.pause(); })');
    await startPlaying(p);
    p.api.prepareBackground();
    p.api.setBackground(true);               // phone locked, music playing
    await sleep(100);
    p.run('navigator.mediaSession.native.pause({ action: "pause" })');   // tap pause on lock screen
    await sleep(3000);
    expect(p.video.paused, 'stays paused');
    expect(p.run('window.__ytPause') === 1, 'YouTube handler still used');
    p.api.kick();
    await sleep(50);
    expect(p.video.paused, 'app nudges never override it');
  });

  await test('LOCK SCREEN play (iOS controls) resumes; pause works even without YouTube handlers', async (page) => {
    const p = page({ nativeMediaSession: true });
    await startPlaying(p);
    p.api.setBackground(true);
    p.run('navigator.mediaSession.native.pause({ action: "pause" })');
    await sleep(800);
    expect(p.video.paused, 'paused from lock screen');
    p.run('navigator.mediaSession.native.play({ action: "play" })');
    await sleep(80);
    expect(!p.video.paused, 'play from lock screen resumes');
  });

  await test('page alone detects leaving the screen (no app notices) and resumes', async (page) => {
    const p = page();
    await startPlaying(p);
    p.systemPause();                          // WebKit pauses first...
    await sleep(60);
    p.run('window.__reallyHidden = true; window.__test.dispatch(document, "visibilitychange")');  // ...then page goes hidden
    await sleep(400);
    expect(!p.video.paused, 'resumed from inside the page');
  });

  await test('pause long after the screen went off (e.g. headphones) is not undone', async (page) => {
    const p = page();
    await startPlaying(p);
    p.run('window.__reallyHidden = true; window.__test.dispatch(document, "visibilitychange")');
    await sleep(2700);                        // locked for a while, still playing
    expect(!p.video.paused, 'still playing while locked');
    p.systemPause();                          // something stops it later
    await sleep(900);
    expect(p.video.paused, 'left paused');
  });

  await test("YouTube's own pause while you're using the app is left alone", async (page) => {
    const p = page();
    await startPlaying(p);
    p.systemPause();                          // e.g. YouTube pauses itself
    await sleep(900);
    expect(p.video.paused, 'not fought');
  });

  await test('lock screen pause in background stays paused', async (page) => {
    const p = page();
    await startPlaying(p);
    p.api.setBackground(true);
    p.api.pause();
    await sleep(900);
    expect(p.video.paused, 'should stay paused');
    p.api.kick();
    await sleep(50);
    expect(p.video.paused, 'kick must not override a user pause');
    p.api.play();
    await sleep(50);
    expect(!p.video.paused, 'lock screen play resumes');
  });

  await test('call (in background): pauses for the whole call, resumes when it ends', async (page) => {
    const p = page();
    await startPlaying(p);
    p.api.setBackground(true);
    p.api.interrupted(true, false);         // call starts
    await sleep(50);
    expect(p.video.paused, 'paused when call starts');
    await sleep(900);
    p.api.kick();                             // app nudges must not resume during call
    await sleep(50);
    expect(p.video.paused, 'still paused during call');
    p.api.interrupted(false, true);          // call ended
    await sleep(50);
    expect(!p.video.paused, 'resumes after the call');
  });

  await test('call race: iOS pauses first, call notice arrives 150ms later -> stays paused', async (page) => {
    const p = page();
    await startPlaying(p);
    p.api.setBackground(true);
    p.systemPause();
    await sleep(150);
    p.api.interrupted(true, false);
    await sleep(900);
    expect(p.video.paused, 'must not auto-resume into the call');
    p.api.interrupted(false, true);
    await sleep(50);
    expect(!p.video.paused, 'resumes after the call');
  });

  await test('call accepted while app is open: pauses, stays paused after app backgrounds', async (page) => {
    const p = page();
    await startPlaying(p);
    p.systemPause();                          // ring tone interrupts
    p.api.interrupted(true, false);
    await sleep(50);
    p.api.setBackground(true);               // call screen takes over
    await sleep(900);
    p.api.kick();
    await sleep(50);
    expect(p.video.paused, 'stays paused during call');
    p.api.interrupted(false, true);
    await sleep(50);
    expect(!p.video.paused, 'resumes after call');
  });

  await test('call when music was already paused: stays paused afterwards', async (page) => {
    const p = page();
    await startPlaying(p);
    p.api.pause();
    await sleep(2100);
    p.api.interrupted(true, false);
    p.api.interrupted(false, true);
    await sleep(100);
    expect(p.video.paused, 'should not start music the user had paused');
  });

  await test('headphones / AirPods disconnected: pauses and stays paused', async (page) => {
    const p = page();
    await startPlaying(p);
    p.api.setBackground(true);
    p.systemPause();                          // WebKit reacts to route change
    await sleep(100);
    p.api.pause();                            // app's route-change handler
    await sleep(900);
    expect(p.video.paused, 'stays paused');
    p.api.setBackground(false);
    p.api.setBackground(true);
    p.api.kick();
    await sleep(700);
    expect(p.video.paused, 'still paused after app state changes');
  });

  await test('headphones disconnected when app sends pause before iOS pause', async (page) => {
    const p = page();
    await startPlaying(p);
    p.api.setBackground(true);
    p.api.pause();
    p.systemPause();
    await sleep(900);
    expect(p.video.paused, 'stays paused');
  });

  await test('user paused in app, then locked phone: stays paused', async (page) => {
    const p = page();
    await startPlaying(p);
    p.run('window.__test.dispatch(document, "touchstart")');
    p.video.pause();                          // tapped YouTube's pause button
    await sleep(50);
    p.api.prepareBackground();
    p.api.setBackground(true);
    await sleep(700);
    p.api.kick();
    await sleep(50);
    expect(p.video.paused, 'stays paused');
  });

  await test('song ends in background: no forced skip (YouTube autoplay decides)', async (page) => {
    const p = page();
    p.run('window.__nexts = 0; navigator.mediaSession.setActionHandler("nexttrack", () => window.__nexts++)');
    await startPlaying(p);
    p.api.setBackground(true);
    p.video.finish();
    await sleep(400);
    expect(p.run('window.__nexts') === 0, 'app must not skip on its own');
    expect(p.video.paused, 'ended song is not restarted');
  });

  await test('lock screen next / previous', async (page) => {
    const p = page();
    p.run('window.__nexts = 0; window.__prevs = 0;' +
          'navigator.mediaSession.setActionHandler("nexttrack", () => window.__nexts++);' +
          'navigator.mediaSession.setActionHandler("previoustrack", () => window.__prevs++)');
    await startPlaying(p);
    p.api.next();
    expect(p.run('window.__nexts') === 1, 'next called');
    p.video.currentTime = 42;
    p.api.previous();
    expect(p.video.currentTime === 0 && p.run('window.__prevs') === 0, 'previous after 3s restarts song');
    p.video.currentTime = 1;
    p.api.previous();
    expect(p.run('window.__prevs') === 1, 'previous near start goes to previous song');
  });

  await test('scrubbing from lock screen seeks', async (page) => {
    const p = page();
    await startPlaying(p);
    p.api.seek(95.5);
    expect(p.video.currentTime === 95.5, 'seeked');
  });

  await test('metadata from YouTube media session is used (no native session)', async (page) => {
    const p = page();
    await startPlaying(p);
    p.run('navigator.mediaSession.metadata = new MediaMetadata({ title: "Song", artist: "Band", artwork: [{src:"https://x/a.jpg", sizes:"96x96"},{src:"https://x/b.jpg", sizes:"512x512"}] })');
    await sleep(120);
    const m = p.last();
    expect(m.title === 'Song' && m.artist === 'Band' && m.artwork === 'https://x/b.jpg', JSON.stringify(m));
  });

  await test('metadata + handlers captured when WebKit has a native media session', async (page) => {
    const p = page({ nativeMediaSession: true });
    await startPlaying(p);
    p.run('window.__nexts = 0; navigator.mediaSession.setActionHandler("nexttrack", () => window.__nexts++)');
    p.run('navigator.mediaSession.metadata = new MediaMetadata({ title: "Native Song", artist: "X" })');
    await sleep(120);
    expect(p.last().title === 'Native Song', 'title from native session');
    expect(p.run('navigator.mediaSession.native.nexttrack') !== undefined, 'still forwarded to WebKit');
    p.api.next();
    expect(p.run('window.__nexts') === 1, 'captured handler used');
  });

  await test('muted feed previews do not take over the player', async (page) => {
    const p = page();
    await startPlaying(p);
    const preview = p.run('const v = new window.__test.HTMLMediaElement(); v.muted = true; v.duration = 30; v');
    preview.play();
    await sleep(100);
    p.api.pause();
    await sleep(50);
    expect(p.video.paused, 'pause targets the real player, not the preview');
  });

  await test('ads: player responses lose adPlacements / playerAds / adSlots', async (page) => {
    const p = page();
    const parsed = p.run(`JSON.parse('{"playabilityStatus":{"status":"OK"},"adPlacements":[1],"playerAds":[2],"adSlots":[3],"streamingData":{}}')`);
    expect(!('adPlacements' in parsed) && !('playerAds' in parsed) && !('adSlots' in parsed), 'JSON.parse pruned');
    expect(parsed.streamingData && parsed.playabilityStatus.status === 'OK', 'video data kept');

    const nested = p.run(`JSON.parse('[{"playerResponse":{"adPlacements":[1],"videoDetails":{"videoId":"x"}}}]')`);
    expect(!('adPlacements' in nested[0].playerResponse) && nested[0].playerResponse.videoDetails, 'nested pruned');

    const fromFetch = await p.run(`new window.__test.Response('{"adPlacements":[1],"videoDetails":{}}').json()`);
    expect(!('adPlacements' in fromFetch) && fromFetch.videoDetails, 'Response.json pruned');

    p.run('var ytInitialPlayerResponse = { adPlacements: [1], playerAds: [1], videoDetails: { title: "t" } };');
    const initial = p.run('ytInitialPlayerResponse');
    expect(!('adPlacements' in initial) && !('playerAds' in initial) && initial.videoDetails, 'inline response pruned');
  });

  await test('ads: cosmetic hiding stylesheet injected', async (page) => {
    const p = page();
    const css = p.styles.map((s) => s.textContent).join('\n');
    expect(css.includes('ytm-promoted-sparkles-web-renderer{display:none!important}'), 'feed ads hidden');
    expect(css.includes('ad-slot-renderer{display:none!important}'), 'ad slots hidden');
  });

  await test('ads: an ad that slips through is muted and skipped, never sped up or seeked', async (page) => {
    const p = page();
    await startPlaying(p);
    p.run('window.__skips = 0; document.querySelectorAll = (s) => s.includes("skip") ? [{ click() { window.__skips++; } }] : []');
    p.classes.add('ad-showing');
    p.video.currentTime = 1; p.video.duration = 215;
    await sleep(400);
    expect(p.video.muted === true, 'muted during ad');
    expect(p.run('window.__skips') > 0, 'skip button pressed');
    expect(p.video.currentTime === 1 && p.video.playbackRate === 1, 'no seeking / speed change (stalls stream)');
    p.classes.delete('ad-showing');
    await sleep(400);
    expect(p.video.muted === false, 'sound restored');
  });

  await test('ads: raw player responses renamed like uBlock ("adPlacements" -> "no_ads")', async (page) => {
    const p = page();
    const body = '{"adPlacements":[{"x":1}],"adSlots":[2],"playerAds":[3],"streamingData":{"formats":[]}}';
    const t = await p.run(`new window.__test.Response(${JSON.stringify(body)}, 'https://m.youtube.com/youtubei/v1/player?key=x').text()`);
    expect(!/adPlacements|adSlots|playerAds/.test(t) && t.includes('"no_ads"') && t.includes('streamingData'), 'fetch text: ' + t);
    const j = await p.run(`new window.__test.Response(${JSON.stringify(body)}, 'https://m.youtube.com/youtubei/v1/player').json()`);
    expect(!('adPlacements' in j) && j.streamingData, 'fetch json');
    const other = await p.run(`new window.__test.Response(${JSON.stringify(body)}, 'https://m.youtube.com/youtubei/v1/browse').text()`);
    expect(other === body, 'unrelated endpoints untouched');
    const x = p.run(`const r = new window.__test.XMLHttpRequest(); r.open('GET', '/watch?v=abc&pbj=1'); r.setBody(${JSON.stringify(body)}); r.responseText`);
    expect(!/adPlacements/.test(x), 'xhr renamed');
  });

  await test('ads: YouTube\'s 17-second anti-blocker delay runs almost instantly', async (page) => {
    const p = page();
    p.run('window.__fired = 0; setTimeout((function () { window.__fired++; }).bind(null), 17000)');
    p.run('window.__other = 0; setTimeout(function () { window.__other++; }, 17000)');
    await sleep(120);
    expect(p.run('window.__fired') === 1, 'native-code 17s timer fired early');
    expect(p.run('window.__other') === 0, 'ordinary 17s timers untouched');
  });

  await test('ads: hidden iframes get the filtered fetch (no clean-fetch bypass)', async (page) => {
    const p = page();
    const ok = p.run(`
      const cw = { fetch: 'clean', Request: 'clean', JSON: { parse: 'clean' } };
      new window.__test.Node().appendChild({ nodeName: 'IFRAME', contentWindow: cw });
      cw.fetch !== 'clean' && cw.Request === window.Request && cw.JSON.parse === JSON.parse
    `);
    expect(ok === true, 'iframe patched');
  });

  await test('ad blocking off: player responses untouched', async () => {
    const ctx = vm.createContext({ console, URL, URLSearchParams, setTimeout, clearTimeout, setInterval, clearInterval });
    vm.runInContext(`
      var window = globalThis; var top = globalThis;
      var location = { hostname: 'm.youtube.com', href: 'https://m.youtube.com/' };
      class Document {} var document = new Document();
      document.documentElement = { appendChild() {} }; document.addEventListener = () => {};
      document.createElement = () => ({}); document.querySelector = () => null;
      window.addEventListener = () => {};
      class Navigator {} var navigator = new Navigator();
      class Response { json() { return Promise.resolve({}); } }
      class HTMLMediaElement {}
      var history = { pushState() {}, back() {} };
      window.__encoreAdblock = false;
    `, ctx);
    vm.runInContext(SCRIPT, ctx);
    const parsed = vm.runInContext(`JSON.parse('{"adPlacements":[1]}')`, ctx);
    expect('adPlacements' in parsed, 'should be untouched when disabled');
  });

  // -------------------------------------------------------------------------
  const failed = results.filter((r) => !r[0]);
  for (const [ok, name, err] of results) console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${err ? '\n      ' + err : ''}`);
  console.log(`\n${results.length - failed.length}/${results.length} passed`);
  process.exit(failed.length ? 1 : 0);
})();
