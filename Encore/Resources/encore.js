/*
 * Encore page script. Injected at document start into every frame.
 *
 *  1. Pages always believe they are visible, so YouTube never pauses itself
 *     when the app goes to the background or the screen locks.
 *  2. YouTube ads are stripped from player responses before the player sees
 *     them, with a skipper + cosmetic CSS as fallback.
 *  3. (Top frame) a media bridge reports playback to the app for the lock
 *     screen, takes play/pause/next/seek commands back, and resumes playback
 *     that iOS pauses while the app is in the background.
 */
(function () {
  'use strict';
  if (window.__encoreBooted) return;
  try { Object.defineProperty(window, '__encoreBooted', { value: true }); } catch (e) { return; }

  var ADBLOCK = window.__encoreAdblock !== false;
  var IS_TOP = window.top === window;
  var IS_YT = /(^|\.)(youtube\.com|youtube-nocookie\.com)$/.test(location.hostname);
  var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.encore;

  function post(msg) {
    try { if (bridge) bridge.postMessage(msg); } catch (e) {}
  }

  function player() {
    return document.querySelector('.html5-video-player');
  }

  function adShowing() {
    var p = player();
    return !!p && (p.classList.contains('ad-showing') || p.classList.contains('ad-interrupting'));
  }

  // ---------------------------------------------------------------------------
  // 1. Always visible
  // ---------------------------------------------------------------------------

  function constantGetter(proto, prop, value) {
    try {
      Object.defineProperty(proto, prop, {
        configurable: true,
        enumerable: true,
        get: function () { return value; }
      });
    } catch (e) {}
  }
  constantGetter(Document.prototype, 'hidden', false);
  constantGetter(Document.prototype, 'webkitHidden', false);
  constantGetter(Document.prototype, 'visibilityState', 'visible');
  constantGetter(Document.prototype, 'webkitVisibilityState', 'visible');
  try { Document.prototype.hasFocus = function () { return true; }; } catch (e) {}

  ['visibilitychange', 'webkitvisibilitychange'].forEach(function (type) {
    window.addEventListener(type, function (e) { e.stopImmediatePropagation(); }, true);
  });

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

    // Player responses parsed from text (fetch/XHR → JSON.parse).
    var nativeParse = JSON.parse;
    JSON.parse = function (text) {
      var out = nativeParse.apply(this, arguments);
      if (typeof text === 'string' && AD_JSON.test(text)) {
        try { prune(out); } catch (e) {}
      }
      return out;
    };

    // Player responses read with response.json().
    var nativeJson = Response.prototype.json;
    Response.prototype.json = function () {
      return nativeJson.apply(this, arguments).then(function (data) {
        try { prune(data); } catch (e) {}
        return data;
      });
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
      '#player-ads',
      '.video-ads',
      '.ytp-ad-module',
      '.ytp-ad-overlay-container',
      '.ytp-ad-image-overlay',
      '.ytp-ad-text-overlay'
    ];
    var addStyle = function () {
      var style = document.createElement('style');
      style.textContent = HIDE.map(function (s) { return s + '{display:none!important}'; }).join('\n');
      (document.head || document.documentElement).appendChild(style);
    };
    if (document.documentElement) addStyle();
    else document.addEventListener('DOMContentLoaded', addStyle);

    // Fallback for ads that still get through: mute, jump to the end, press Skip.
    var SKIP = '.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, ' +
               '.ytp-ad-skip-button-slot button, button[class*="skip-ad"], button[class*="ad-skip"]';
    var beforeAd = null;
    setInterval(function () {
      var p = player();
      var video = p && p.querySelector('video');
      if (!video) return;
      if (adShowing()) {
        if (!beforeAd) beforeAd = { muted: video.muted, rate: video.playbackRate || 1 };
        video.muted = true;
        try { video.playbackRate = 16; } catch (e) {}
        if (isFinite(video.duration) && video.duration > 0 && video.currentTime < video.duration - 0.25) {
          try { video.currentTime = video.duration - 0.1; } catch (e) {}
        }
        var buttons = document.querySelectorAll(SKIP);
        for (var i = 0; i < buttons.length; i++) buttons[i].click();
      } else if (beforeAd) {
        video.muted = beforeAd.muted;
        try { video.playbackRate = beforeAd.rate; } catch (e) {}
        beforeAd = null;
      }
    }, 250);
  }

  // ---------------------------------------------------------------------------
  // 3. Media bridge (top frame only)
  // ---------------------------------------------------------------------------

  if (!IS_TOP) return;

  var media = null;          // the element we report and control
  var wantPlay = false;      // the user expects audio to be playing
  var userPaused = false;    // paused on purpose (app, lock screen, headphones)
  var background = false;    // app is in the background (set by the app)
  var interrupted = false;   // phone call / Siri / alarm in progress
  var resumeAfterInterruption = false;
  var lastPauseAt = 0;
  var transitionUntil = 0;   // next/previous in flight: don't fight the player
  var resumeTimer = null;
  var reportTimer = null;
  var lastTick = 0;

  // --- Media Session: capture YouTube's metadata and next/previous handlers ---

  var handlers = {};
  var metadata = null;
  var session = navigator.mediaSession;

  if (session) {
    var nativeSetHandler = session.setActionHandler;
    session.setActionHandler = function (action, handler) {
      handlers[action] = handler;
      try { return nativeSetHandler.call(session, action, handler); } catch (e) {}
    };
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
      setActionHandler: function (action, handler) { handlers[action] = handler; },
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

  // --- Reporting ---

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

  // --- Playback control ---

  function safePlay(m) {
    try {
      var p = m.play();
      if (p && p.catch) p.catch(function () {});
    } catch (e) {}
  }

  function shouldResume() {
    return background && wantPlay && !userPaused && !interrupted &&
           media && media.paused && !media.ended && Date.now() > transitionUntil;
  }

  function scheduleResume() {
    clearTimeout(resumeTimer);
    resumeTimer = setTimeout(function () {
      if (shouldResume()) safePlay(media);
    }, 500);  // leaves time for a call/headphone notice from the app to arrive first
  }

  function goNext() {
    transitionUntil = Date.now() + 3000;
    if (handlers.nexttrack) {
      try { handlers.nexttrack({ action: 'nexttrack' }); return; } catch (e) {}
    }
    var mp = document.getElementById('movie_player');
    if (mp && typeof mp.nextVideo === 'function') { mp.nextVideo(); return; }
    var button = document.querySelector('.ytp-next-button, button[aria-label^="Next"]');
    if (button) button.click();
  }

  function goPrevious() {
    if (media && media.currentTime > 3) { media.currentTime = 0; scheduleReport('seeked'); return; }
    transitionUntil = Date.now() + 3000;
    if (handlers.previoustrack) {
      try { handlers.previoustrack({ action: 'previoustrack' }); return; } catch (e) {}
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
        if (type === 'playing') interrupted = false;  // audio is flowing again
        break;
      case 'pause':
        if (adShowing()) return;
        lastPauseAt = Date.now();
        if (shouldResume()) {
          // iOS paused us on the way to the background: play straight through.
          scheduleResume();
          return;
        }
        if (!background || userPaused || m.ended) wantPlay = false;
        break;
      case 'ended':
        wantPlay = false;
        if (background && !adShowing()) {
          // Hop to the next song immediately, before iOS suspends the idle page.
          wantPlay = true;
          goNext();
        }
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
    if (e.target === media && Date.now() - lastTick > 10000) {
      lastTick = Date.now();
      report('tick');
    }
  }, true);

  window.addEventListener('pagehide', function () {
    post({ type: 'media', event: 'gone' });
  });

  // --- API used by the app (window.__encore.*) ---

  window.__encore = {
    play: function () {
      userPaused = false;
      wantPlay = true;
      interrupted = false;
      if (media) safePlay(media);
    },
    pause: function () {
      userPaused = true;
      wantPlay = false;
      clearTimeout(resumeTimer);
      if (media) media.pause();
    },
    toggle: function () {
      if (media && !media.paused) window.__encore.pause(); else window.__encore.play();
    },
    next: function () { wantPlay = true; userPaused = false; goNext(); },
    previous: function () { goPrevious(); },
    seek: function (seconds) {
      if (media && isFinite(seconds)) { media.currentTime = seconds; scheduleReport('seeked'); }
    },
    setBackground: function (value) {
      background = !!value;
      if (background) scheduleResume();
    },
    kick: function () {
      if (wantPlay && !userPaused && !interrupted && media && media.paused && !media.ended) safePlay(media);
    },
    interrupted: function (began, resume) {
      if (began) {
        if (!interrupted) {
          resumeAfterInterruption = !userPaused &&
            ((media && !media.paused) || wantPlay || Date.now() - lastPauseAt < 2000);
        }
        interrupted = true;
        clearTimeout(resumeTimer);
        if (media && !media.paused) media.pause();
      } else {
        interrupted = false;
        if (resume && resumeAfterInterruption) window.__encore.play();
        resumeAfterInterruption = false;
      }
    },
    state: function () { report('state'); }
  };
})();
