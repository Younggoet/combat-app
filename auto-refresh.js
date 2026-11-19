// Combat — keeps every open page on the latest deploy.
// Checks the page's ETag whenever the app comes back to the foreground
// (and every minute while open). If a new version shipped, it reloads.
(function () {
  if (!('fetch' in window)) return;
  var url = location.pathname + location.search;
  var base = null, busy = false;

  function tag(res) { return res.headers.get('etag') || res.headers.get('last-modified'); }

  function check() {
    if (busy) return;
    busy = true;
    fetch(url, { method: 'HEAD', cache: 'no-store' }).then(function (res) {
      var t = tag(res);
      if (!t) return;
      if (base === null) { base = t; return; }
      if (t === base) return;
      var a = document.activeElement;
      var typing = a && /^(INPUT|TEXTAREA)$/.test(a.tagName) && a.value;
      if (typing) return; // don't wipe a message being typed; try next time
      location.reload();
    }).catch(function () {}).then(function () { busy = false; });
  }

  check();
  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'visible') check();
  });
  window.addEventListener('focus', check);
  window.addEventListener('pageshow', function (e) { if (e.persisted) check(); });
  setInterval(function () { if (document.visibilityState === 'visible') check(); }, 60000);
})();
