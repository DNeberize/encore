/*
 * Encore page script. Injected at document start into every frame.
 *
 *  1. Pages always believe they are visible, so YouTube never pauses itself
 *     when the app goes to the background or the screen locks.
 *  2. YouTube ads are stripped from player responses before the player sees
 *     them, with a mute-and-skip fallback and cosmetic CSS.
 *  3. (Top frame) playback keeper: when iOS pauses the video because the app
 *     left the screen, it is resumed on the spot. Pauses you make (in the
 *     page, on the lock screen / Control Center, or by the app for calls and
 *     unplugged headphones) are always respected.
 *  4. (Top frame) the app's two pages: "browse" (home, search, channels)
 *     hands every video to "player" (the watch page, full screen or the mini
 *     player), so browsing keeps its place while something plays.
 */
(function () {
  'use strict';
  if (window.__encoreBooted) return;
  try { Object.defineProperty(window, '__encoreBooted', { value: true }); } catch (e) { return; }

  var ADBLOCK = window.__encoreAdblock !== false;
  var IS_TOP = window.top === window;
  var IS_YT = /(^|\.)(youtube\.com|youtube-nocookie\.com)$/.test(location.hostname);
  var IS_PLAYER = window.__encoreRole === 'player';
  var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.encore;

  function post(msg) {
    try { if (bridge) bridge.postMessage(msg); } catch (e) {}
  }

  function player() {
    return document.querySelector('.html5-video-player');
  }

  function addCSS(css) {
    var add = function () {
      var style = document.createElement('style');
      style.textContent = css;
      (document.head || document.documentElement).appendChild(style);
    };
    if (document.documentElement) add();
    else document.addEventListener('DOMContentLoaded', add);
  }

  function adShowing() {
    var p = player();
    return !!p && (p.classList.contains('ad-showing') || p.classList.contains('ad-interrupting'));
  }

  // ---------------------------------------------------------------------------
  // 1. Always visible
  // ---------------------------------------------------------------------------

  // Keep a way to read the real state before hiding it from the page.
  var hiddenDesc = Object.getOwnPropertyDescriptor(Document.prototype, 'hidden');
  function reallyHidden() {
    try { return !!(hiddenDesc && hiddenDesc.get && hiddenDesc.get.call(document)); } catch (e) { return false; }
  }
  var hiddenAt = 0;          // when the app really went off screen

  function constantGetter(target, prop, value) {
    try {
      Object.defineProperty(target, prop, {
        configurable: true,
        enumerable: true,
        get: function () { return value; }
      });
    } catch (e) {}
  }
  // On the prototype and on the document itself, so no lookup path sees the truth.
  [Document.prototype, document].forEach(function (target) {
    constantGetter(target, 'hidden', false);
    constantGetter(target, 'webkitHidden', false);
    constantGetter(target, 'visibilityState', 'visible');
    constantGetter(target, 'webkitVisibilityState', 'visible');
  });
  try { Document.prototype.hasFocus = function () { return true; }; } catch (e) {}

  var onRealVisibility = null;  // set by the playback keeper (top frame)
  ['visibilitychange', 'webkitvisibilitychange'].forEach(function (type) {
    window.addEventListener(type, function (e) {
      e.stopImmediatePropagation();
      if (type !== 'visibilitychange') return;
      var hidden = reallyHidden();
      hiddenAt = hidden ? Date.now() : 0;
      if (onRealVisibility) onRealVisibility(hidden);
    }, true);
  });
  window.addEventListener('freeze', function (e) { e.stopImmediatePropagation(); }, true);

  if (IS_YT) {
    // YouTube's "Video paused. Continue watching?" checks the last-activity time.
    setInterval(function () { try { window._lact = Date.now(); } catch (e) {} }, 60000);
  }

  // ---------------------------------------------------------------------------
  // 2. YouTube ad blocking
  // ---------------------------------------------------------------------------

  if (IS_YT && ADBLOCK) {
    var AD_KEYS = ['adPlacements', 'playerAds', 'adSlots', 'adBreakHeartbeatParams'];
    var AD_JSON = /"(adPlacements|playerAds|adSlots)"/;

    var strip = function (o) {
      if (!o || typeof o !== 'object') return;
      for (var i = 0; i < AD_KEYS.length; i++) {
        if (AD_KEYS[i] in o) delete o[AD_KEYS[i]];
      }
    };
    var pruneOne = function (o) {
      if (!o || typeof o !== 'object') return;
      strip(o);
      strip(o.playerResponse);
      if (o.response) {
        strip(o.response);
        strip(o.response.playerResponse);
      }
    };
    var prune = function (o) {
      if (Array.isArray(o)) { for (var i = 0; i < o.length; i++) pruneOne(o[i]); }
      else pruneOne(o);
      return o;
    };

    // Like uBlock Origin today: rename the ad fields in the raw player
    // responses ("adPlacements" -> "no_ads") so the player never sees ads,
    // while the JSON keeps exactly the shape YouTube expects.
    var AD_URL = /\/youtubei\/v1\/(player|get_watch|next|reel)|\/watch\?|\/playlist\?/;
    var renameAds = function (text) {
      if (typeof text !== 'string' || text.indexOf('"ad') === -1 && text.indexOf('"playerAds"') === -1) return text;
      return text.replace(/"(adPlacements|adSlots|playerAds)"/g, '"no_ads"');
    };

    // Anything parsed from text that still carries ad fields.
    var nativeParse = JSON.parse;
    JSON.parse = function (text) {
      var out = nativeParse.apply(this, arguments);
      if (typeof text === 'string' && AD_JSON.test(text)) {
        try { prune(out); } catch (e) {}
      }
      return out;
    };

    // fetch() responses.
    var nativeText = Response.prototype.text;
    Response.prototype.text = function () {
      var url = this.url || '';
      return nativeText.apply(this, arguments).then(function (t) {
        return AD_URL.test(url) ? renameAds(t) : t;
      });
    };
    Response.prototype.json = function () {
      var url = this.url || '';
      return nativeText.call(this).then(function (t) {
        var data = nativeParse.call(JSON, AD_URL.test(url) ? renameAds(t) : t);
        try { prune(data); } catch (e) {}
        return data;
      });
    };

    // XMLHttpRequest responses.
    var nativeOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (method, url) {
      this.__encoreURL = String(url);
      return nativeOpen.apply(this, arguments);
    };
    ['responseText', 'response'].forEach(function (prop) {
      var desc = Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype, prop);
      if (!desc || !desc.get) return;
      try {
        Object.defineProperty(XMLHttpRequest.prototype, prop, {
          configurable: true,
          enumerable: desc.enumerable,
          get: function () {
            var v = desc.get.call(this);
            return typeof v === 'string' && this.__encoreURL && AD_URL.test(this.__encoreURL) ? renameAds(v) : v;
          }
        });
      } catch (e) {}
    });

    // YouTube grabs an untouched fetch() from a fresh hidden iframe to get
    // around blockers; hand that iframe our (filtered) versions instead.
    var patchFrame = function (node) {
      if (!node || node.nodeName !== 'IFRAME') return;
      try {
        var w = node.contentWindow;
        if (!w) return;
        w.fetch = window.fetch.bind(window);
        w.Request = window.Request;
        w.Response = window.Response;
        w.XMLHttpRequest = window.XMLHttpRequest;
        w.JSON.parse = JSON.parse;
      } catch (e) {}
    };
    ['appendChild', 'insertBefore'].forEach(function (name) {
      var original = Node.prototype[name];
      Node.prototype[name] = function (node) {
        var result = original.apply(this, arguments);
        patchFrame(node);
        return result;
      };
    });

    // When YouTube suspects a blocker it holds playback back with a 17-second
    // timer (the endless spinner). Run that timer almost immediately instead.
    var nativeSetTimeout = window.setTimeout;
    window.setTimeout = function (fn, delay) {
      if (delay === 17000 && typeof fn === 'function' &&
          /\[native code\]/.test(Function.prototype.toString.call(fn))) {
        arguments[1] = 17;
      }
      return nativeSetTimeout.apply(this, arguments);
    };

    // The first player response is embedded inline in the watch page.
    var initialResponse;
    try {
      Object.defineProperty(window, 'ytInitialPlayerResponse', {
        configurable: true,
        get: function () { return initialResponse; },
        set: function (v) { initialResponse = prune(v); }
      });
    } catch (e) {}

    // Cosmetic: one rule per selector so an unsupported selector can't void the rest.
    var HIDE = [
      'ytm-promoted-sparkles-web-renderer',
      'ytm-promoted-sparkles-text-search-renderer',
      'ytm-promoted-video-renderer',
      'ytm-companion-ad-renderer',
      'ytm-companion-slot',
      'ad-slot-renderer',
      'ytm-rich-item-renderer:has(ad-slot-renderer)',
      'ytm-item-section-renderer:has(ad-slot-renderer)',
      'ytm-statement-banner-renderer',
      'ytm-mealbar-promo-renderer',
      'ytmusic-mealbar-promo-renderer',
      'ytd-ad-slot-renderer',
      'ytd-rich-item-renderer:has(ytd-ad-slot-renderer)',
      'ytd-in-feed-ad-layout-renderer',
      'ytd-promoted-sparkles-web-renderer',
      'ytd-display-ad-renderer',
      'ytd-companion-slot-renderer',
      'ytd-action-companion-ad-renderer',
      'ytd-banner-promo-renderer',
      'ytd-statement-banner-renderer',
      'ytd-player-legacy-desktop-watch-ads-renderer',
      'ytd-engagement-panel-section-list-renderer[target-id="engagement-panel-ads"]',
      'ytd-enforcement-message-view-model',
      'tp-yt-paper-dialog:has(ytd-enforcement-message-view-model)',
      '#masthead-ad',
      '.ytp-ad-overlay-container',
      '.ytp-ad-image-overlay',
      '.ytp-ad-text-overlay'
    ];
    addCSS(HIDE.map(function (s) { return s + '{display:none!important}'; }).join('\n'));

    // Fallback for an ad that still gets through: keep it silent and press
    // Skip as soon as it appears. No speeding up or seeking: that stalls the
    // stream (spinner) and, with ads stitched into the video, skips the song.
    var SKIP = '.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, ' +
               '.ytp-ad-skip-button-slot button, button[class*="skip-ad"], button[class*="ad-skip"]';
    var beforeAd = null;
    setInterval(function () {
      var p = player();
      var video = p && p.querySelector('video');
      if (!video) return;
      if (adShowing()) {
        if (!beforeAd) {
          beforeAd = { muted: video.muted };
          video.muted = true;
        }
        var buttons = document.querySelectorAll(SKIP);
        for (var i = 0; i < buttons.length; i++) buttons[i].click();
      } else if (beforeAd) {
        video.muted = beforeAd.muted;
        beforeAd = null;
      }
    }, 300);
  }

  // ---------------------------------------------------------------------------
  // 3. Playback keeper + media bridge (top frame only)
  // ---------------------------------------------------------------------------

  if (!IS_TOP) return;

  var media = null;          // the audible element we follow
  var wantPlay = false;      // music is supposed to be playing
  var userPaused = false;    // paused on purpose: page tap, lock screen, the app (calls, headphones)
  var interrupted = false;   // call / Siri / alarm in progress (told by the app)
  var resumeAfterInterruption = false;
  var leaving = false;       // app resigned active (told by the app)
  var backgroundAt = 0;      // app entered the background (told by the app)
  var lastTouchAt = 0;
  var lastPauseAt = 0;
  var pausedUnexplained = false;  // last pause had no known cause (may turn out to be iOS's)
  var transitionUntil = 0;   // next/previous in flight: don't fight the player
  var resumeTimers = [];
  var reportTimer = null;
  var lastTick = 0;

  function now() { return Date.now(); }

  ['touchstart', 'touchend', 'pointerdown', 'mousedown', 'keydown'].forEach(function (type) {
    document.addEventListener(type, function (e) { if (e.isTrusted) lastTouchAt = now(); }, true);
  });

  function userJustTouched() { return now() - lastTouchAt < 1000; }

  // iOS pauses web video while the app leaves the screen (Home Screen, app
  // switch, screen lock): from "resign active" until shortly after the page
  // really becomes hidden.
  function leavingScreen() {
    return leaving ||
      (hiddenAt > 0 && now() - hiddenAt < 2500) ||
      (backgroundAt > 0 && now() - backgroundAt < 2500);
  }

  function safePlay(m) {
    try {
      var p = m.play();
      if (p && p.catch) p.catch(function () {});
    } catch (e) {}
  }

  function canResume() {
    return wantPlay && !userPaused && !interrupted && !!media && media.paused && !media.ended &&
           !adShowing() && now() > transitionUntil;
  }

  function clearResume() {
    resumeTimers.forEach(clearTimeout);
    resumeTimers = [];
  }

  // Resume straight away inside the page (no round trip to the app, which can
  // arrive after iOS has frozen the page). The first try waits a beat so a
  // call notice from the app can land first; retries cover iOS refusing or
  // pausing again while it settles.
  function resumeSoon() {
    clearResume();
    [200, 600, 1300, 2500].forEach(function (delay) {
      resumeTimers.push(setTimeout(function () { if (canResume()) safePlay(media); }, delay));
    });
  }

  // The app is leaving the screen: a pause that landed just before we knew
  // that was iOS's doing, so undo it too.
  function onLeaving() {
    if (pausedUnexplained && now() - lastPauseAt < 1500 && !userPaused && !interrupted) {
      wantPlay = true;
    }
    pausedUnexplained = false;
    if (canResume()) resumeSoon();
  }

  onRealVisibility = function (hidden) {
    if (hidden) onLeaving();
  };

  // --- Media Session: lock screen & Control Center ---
  // iOS's own lock-screen controls call these handlers. Ours record that the
  // user asked (so a lock-screen pause is never auto-resumed) and then hand
  // over to YouTube's handler, or act on the video directly.

  var pageHandlers = {};
  var metadata = null;
  var session = navigator.mediaSession;

  function userIntent(action) {
    if (action === 'pause' || action === 'stop') {
      userPaused = true;
      wantPlay = false;
      pausedUnexplained = false;
      clearResume();
    } else if (action === 'play') {
      userPaused = false;
      wantPlay = true;
      interrupted = false;
    } else if (action === 'nexttrack' || action === 'previoustrack') {
      transitionUntil = now() + 3000;
    }
  }

  function actionHandler(action) {
    return function (details) {
      userIntent(action);
      var handler = pageHandlers[action];
      if (handler) {
        try { return handler.apply(this, arguments); } catch (e) {}
      }
      if (!media) return;
      if (action === 'pause' || action === 'stop') media.pause();
      else if (action === 'play') safePlay(media);
      else if (action === 'seekto' && details && isFinite(details.seekTime)) media.currentTime = details.seekTime;
    };
  }

  if (session) {
    var nativeSetHandler = session.setActionHandler;
    var setNative = function (action, fn) {
      try { nativeSetHandler.call(session, action, fn); } catch (e) {}
    };
    session.setActionHandler = function (action, handler) {
      pageHandlers[action] = handler || null;
      var always = action === 'play' || action === 'pause';
      setNative(action, handler || always ? actionHandler(action) : null);
    };
    setNative('play', actionHandler('play'));
    setNative('pause', actionHandler('pause'));

    var metaDesc = window.MediaSession && Object.getOwnPropertyDescriptor(MediaSession.prototype, 'metadata');
    if (metaDesc && metaDesc.get && metaDesc.set) {
      try {
        Object.defineProperty(session, 'metadata', {
          configurable: true,
          get: function () { return metaDesc.get.call(session); },
          set: function (v) { metaDesc.set.call(session, v); metadata = v; scheduleReport('metadata'); }
        });
      } catch (e) {}
    }
  } else {
    session = {
      playbackState: 'none',
      setActionHandler: function (action, handler) { pageHandlers[action] = handler || null; },
      setPositionState: function () {},
      setMicrophoneActive: function () {},
      setCameraActive: function () {}
    };
    Object.defineProperty(session, 'metadata', {
      configurable: true,
      get: function () { return metadata; },
      set: function (v) { metadata = v; scheduleReport('metadata'); }
    });
    try {
      Object.defineProperty(Navigator.prototype, 'mediaSession', {
        configurable: true,
        get: function () { return session; }
      });
    } catch (e) {}
    if (typeof window.MediaMetadata !== 'function') {
      window.MediaMetadata = function MediaMetadata(init) {
        init = init || {};
        this.title = init.title || '';
        this.artist = init.artist || '';
        this.album = init.album || '';
        this.artwork = init.artwork || [];
      };
    }
  }

  // --- Reporting (in-app player bar, tab speaker icons) ---

  function cleanTitle() {
    return (document.title || '')
      .replace(/^\(\d+\)\s*/, '')
      .replace(/\s*[-–|]\s*YouTube( Music)?$/, '')
      .trim();
  }

  function channelName() {
    var el = document.querySelector(
      '.slim-owner-channel-name, ytm-slim-owner-renderer .yt-core-attributed-string, ' +
      '#owner #channel-name a, .ytp-title-channel-name, ytmusic-player-bar .byline a'
    );
    return el ? (el.textContent || '').trim() : '';
  }

  function videoId() {
    try { return new URL(location.href).searchParams.get('v'); } catch (e) { return null; }
  }

  function bestArtwork(list) {
    if (!list || !list.length) return '';
    var best = null, bestSize = -1;
    for (var i = 0; i < list.length; i++) {
      var size = parseInt(String(list[i].sizes || '0').split('x')[0], 10) || 0;
      if (size >= bestSize) { best = list[i]; bestSize = size; }
    }
    try { return new URL(best.src, location.href).href; } catch (e) { return ''; }
  }

  function report(event) {
    if (!media || adShowing()) return;
    var m = media;
    var md = metadata || (session && session.metadata) || null;
    var id = videoId();
    post({
      type: 'media',
      event: event,
      video: id || '',
      playing: !m.paused && !m.ended,
      title: (md && md.title) || cleanTitle(),
      artist: (md && md.artist) || channelName() || location.hostname.replace(/^(www|m)\./, ''),
      album: (md && md.album) || '',
      artwork: bestArtwork(md && md.artwork) || (id ? 'https://i.ytimg.com/vi/' + id + '/hqdefault.jpg' : ''),
      duration: isFinite(m.duration) ? m.duration : 0,
      position: m.currentTime || 0,
      rate: m.playbackRate || 1,
      live: m.duration === Infinity
    });
  }

  function scheduleReport(event) {
    clearTimeout(reportTimer);
    reportTimer = setTimeout(function () { report(event); }, 60);
  }

  // --- Next / previous ---

  function goNext() {
    transitionUntil = now() + 3000;
    if (pageHandlers.nexttrack) {
      try { pageHandlers.nexttrack({ action: 'nexttrack' }); return; } catch (e) {}
    }
    var mp = document.getElementById('movie_player');
    if (mp && typeof mp.nextVideo === 'function') { mp.nextVideo(); return; }
    var button = document.querySelector('.ytp-next-button, button[aria-label^="Next"]');
    if (button) button.click();
  }

  function goPrevious() {
    if (media && media.currentTime > 3) { media.currentTime = 0; scheduleReport('seeked'); return; }
    transitionUntil = now() + 3000;
    if (pageHandlers.previoustrack) {
      try { pageHandlers.previoustrack({ action: 'previoustrack' }); return; } catch (e) {}
    }
    var mp = document.getElementById('movie_player');
    if (mp && typeof mp.previousVideo === 'function') { mp.previousVideo(); return; }
    if (media) { media.currentTime = 0; scheduleReport('seeked'); }
  }

  // --- Media events (captured on document; media events don't bubble) ---

  function onMediaEvent(m, type) {
    if (m !== media) {
      // Only a real, audible playback takes over (ignores muted feed previews).
      if ((type !== 'play' && type !== 'playing') || m.muted) return;
      media = m;
    }

    switch (type) {
      case 'play':
      case 'playing':
        wantPlay = true;
        userPaused = false;
        pausedUnexplained = false;
        if (type === 'playing') interrupted = false;  // audio is flowing again
        break;
      case 'pause':
        if (adShowing()) return;
        lastPauseAt = now();
        if (userPaused || interrupted || m.ended || userJustTouched()) {
          // Your pause (or a call): respected.
          wantPlay = false;
          pausedUnexplained = false;
          break;
        }
        if (wantPlay && leavingScreen()) {
          // iOS's pause on the way out: undo it. Not reported, so the lock
          // screen never flips to "paused".
          resumeSoon();
          return;
        }
        pausedUnexplained = wantPlay;
        wantPlay = false;
        break;
      case 'ended':
        wantPlay = false;
        pausedUnexplained = false;
        break;
    }
    scheduleReport(type);
  }

  ['play', 'playing', 'pause', 'ended', 'ratechange', 'durationchange', 'loadedmetadata', 'seeked']
    .forEach(function (type) {
      document.addEventListener(type, function (e) {
        if (e.target instanceof HTMLMediaElement) onMediaEvent(e.target, type);
      }, true);
    });

  document.addEventListener('timeupdate', function (e) {
    if (e.target === media && now() - lastTick > 10000) {
      lastTick = now();
      report('tick');
    }
  }, true);

  window.addEventListener('pagehide', function () {
    post({ type: 'media', event: 'gone' });
  });

  // YouTube's idle "Continue watching?" check also listens for key presses;
  // while off screen send a harmless Alt press once a minute.
  setInterval(function () {
    if (!reallyHidden()) return;
    ['keydown', 'keyup'].forEach(function (type) {
      try {
        document.dispatchEvent(new KeyboardEvent(type, { bubbles: true, cancelable: true, keyCode: 18, which: 18 }));
      } catch (e) {}
    });
  }, 60000);

  // ---------------------------------------------------------------------------
  // 4. The app's two pages
  // ---------------------------------------------------------------------------

  var IS_MAIN_YT = /^(m|www)\.youtube\.com$|^youtube\.com$/.test(location.hostname);
  var ownClick = false;      // our own navigate() click: never intercepted

  function isVideoPath(path) {
    return path === '/watch' || /^\/live\/[^/]+$/.test(path);
  }

  function currentPath() {
    try { return new URL(location.href).pathname; } catch (e) { return ''; }
  }

  // In-page navigation through YouTube's own router (no page reload): a click
  // on a link, like a tap on any of YouTube's own.
  function navigate(href) {
    var url;
    try { url = new URL(href, location.href); } catch (e) { return false; }
    var app = document.querySelector('ytm-app');
    if (!app || !/(^|\.)youtube\.com$/.test(url.hostname)) return false;
    var a = document.createElement('a');
    a.href = url.pathname + url.search + url.hash;
    a.style.display = 'none';
    app.appendChild(a);
    ownClick = true;
    try { a.click(); } finally { ownClick = false; a.remove(); }
    return true;
  }

  if (IS_MAIN_YT) {
    if (IS_PLAYER) {
      // Watch page like the YouTube app: video at the very top, no top bar
      // (YouTube's own "header in player" layout) and no tab bar. Also no
      // floating copy of the related-video chips: it pins itself under the top
      // bar we hide, so it hung over the list; the chip row in the list stays.
      addCSS([
        'ytm-mobile-topbar-renderer,ytm-pivot-bar-renderer,ytm-related-chip-cloud-renderer{display:none!important}',
        '.player-container.sticky-player{top:0!important}',
        'ytm-app.sticky-player{padding-top:0!important}',
        'html.watch-scroll.sticky-player{scroll-padding-top:56.25vw!important}'
      ].join('\n'));
    } else {
      // Room at the end of the page so the mini player never covers the last item.
      addCSS('ytm-app::after{content:"";display:block;height:var(--encore-bottom-inset,0px)}');
    }

    // Videos tapped while browsing go to the player; anything else tapped in
    // the player (a channel, a hashtag, Shorts) goes back to browsing.
    window.addEventListener('click', function (e) {
      if (ownClick || e.defaultPrevented || e.button > 0 || e.metaKey || e.ctrlKey || e.shiftKey) return;
      var a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
      if (!a) return;
      var url;
      try { url = new URL(a.getAttribute('href'), location.href); } catch (err) { return; }
      if (!/(^|\.)youtube\.com$/.test(url.hostname) || url.hostname === 'music.youtube.com') return;
      var video = isVideoPath(url.pathname);
      if (IS_PLAYER === video) return;
      e.preventDefault();
      e.stopImmediatePropagation();
      post({ type: IS_PLAYER ? 'browse' : 'openVideo', url: url.href });
    }, true);

    // Route changes. Browsing never stays on a watch page (one opened some
    // other way than a link goes to the player too); the player reports
    // where it is so the app knows when the video has gone.
    var lastPath = currentPath();
    var onRoute = function (pushed) {
      var path = currentPath();
      if (path === lastPath) return;
      lastPath = path;
      var video = isVideoPath(path);
      if (!IS_PLAYER && video && pushed && !ownClick) {
        post({ type: 'openVideo', url: location.href });
        history.back();
        return;
      }
      post({ type: 'route', url: location.href, video: video });
    };
    ['pushState', 'replaceState'].forEach(function (name) {
      var original = history[name];
      if (typeof original !== 'function') return;
      history[name] = function () {
        var result = original.apply(this, arguments);
        onRoute(name === 'pushState');
        return result;
      };
    });
    window.addEventListener('popstate', function () { onRoute(false); });
  }

  // --- API used by the app (window.__encore.*) ---

  window.__encore = {
    play: function () {
      userIntent('play');
      if (media) safePlay(media);
    },
    pause: function () {
      userIntent('pause');
      if (media) media.pause();
    },
    toggle: function () {
      if (media && !media.paused) window.__encore.pause(); else window.__encore.play();
    },
    next: function () { userIntent('play'); goNext(); },
    previous: function () { goPrevious(); },
    seek: function (seconds) {
      if (media && isFinite(seconds)) { media.currentTime = seconds; scheduleReport('seeked'); }
    },
    // App is about to leave the screen: remember that music is playing.
    prepareBackground: function () {
      leaving = true;
      if (media && !media.paused && !media.ended && !userPaused) wantPlay = true;
      onLeaving();
    },
    setBackground: function (value) {
      leaving = false;
      backgroundAt = value ? now() : 0;
      if (value) onLeaving();
    },
    kick: function () {
      if (leavingScreen() && canResume()) safePlay(media);
    },
    interrupted: function (began, resume) {
      if (began) {
        if (!interrupted) {
          resumeAfterInterruption = !userPaused &&
            ((media && !media.paused) || wantPlay || now() - lastPauseAt < 2000);
        }
        interrupted = true;
        clearResume();
        if (media && !media.paused) media.pause();
      } else {
        interrupted = false;
        if (resume && resumeAfterInterruption) window.__encore.play();
        resumeAfterInterruption = false;
      }
    },
    state: function () { report('state'); },
    // Opens a YouTube URL in this page without reloading it. False if it can't.
    open: function (href) { return navigate(href); },
    // Stops everything in the page (feed previews too), e.g. when a video opens.
    pauseAll: function () {
      if (media && !media.paused) window.__encore.pause();
      var videos = document.querySelectorAll('video');
      for (var i = 0; i < videos.length; i++) {
        if (!videos[i].paused) videos[i].pause();
      }
    },
    setBottomInset: function (px) {
      try { document.documentElement.style.setProperty('--encore-bottom-inset', (px | 0) + 'px'); } catch (e) {}
    },
    // Top of YouTube's bottom tab bar (CSS px from the top of the viewport).
    tabBarTop: function () {
      var bar = document.querySelector('ytm-pivot-bar-renderer');
      if (!bar) return null;
      var rect = bar.getBoundingClientRect();
      return rect.height > 0 ? rect.top : null;
    }
  };
})();
