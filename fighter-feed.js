/* Latest Feed for fighter profiles (league.html and cr-draft.html).
   Watches for the #fpfeed slot, then fills it with Combat summaries and
   mixed-source coverage from get-fighter-feed. */
(function () {
  var EP = 'https://combat-sync.netlify.app/.netlify/functions/get-fighter-feed?fighter=';
  var esc = function (s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); };
  var okUrl = function (u) { return /^https?:\/\//i.test(u || '') ? u : '#'; };
  var GOLD = '#D4AF37', DIM = '#9AA3B8', LINE = '#1F2D52';
  var H = "font-family:'Oswald',sans-serif;font-weight:700;";
  function ago(d) {
    var s = (Date.now() - new Date(d).getTime()) / 1000;
    if (!(s >= 0)) return '';
    if (s < 3600) return Math.max(1, Math.round(s / 60)) + 'm ago';
    if (s < 86400) return Math.round(s / 3600) + 'h ago';
    if (s < 86400 * 14) return Math.round(s / 86400) + 'd ago';
    return new Date(d).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
  }
  function render(el, data) {
    var sums = data.summaries || [], cov = data.coverage || [];
    if (!sums.length && !cov.length) return;
    var h = '';
    sums.forEach(function (s, i) {
      var src = (s.sources || []).map(function (x) {
        return '<a href="' + esc(okUrl(x.url)) + '" target="_blank" rel="noopener" style="color:' + GOLD + ';text-decoration:none;border-bottom:1px solid ' + GOLD + '66">' + esc(x.name) + '</a>';
      }).join(' &middot; ');
      h += '<div style="' + (i ? 'border-top:1px solid ' + LINE + ';padding-top:16px;' : '') + 'margin-bottom:16px">' +
        '<div style="' + H + 'font-size:12px;letter-spacing:2px;color:' + GOLD + '">' + esc(s.kind) + '</div>' +
        '<div style="' + H + 'font-size:19px;line-height:1.2;margin:6px 0 8px;color:#F5F2EA">' + esc(s.headline) + '</div>' +
        '<div style="font-size:14px;line-height:1.55;color:#DAD7CE">' + esc(s.body) + '</div>' +
        (s.take ? '<div style="font-size:14px;line-height:1.5;margin-top:10px;color:#F5F2EA"><span style="' + H + 'font-size:12px;letter-spacing:2px;color:' + GOLD + ';margin-right:8px">COMBAT TAKE</span>' + esc(s.take) + '</div>' : '') +
        (src ? '<div style="font-size:12.5px;color:' + DIM + ';margin-top:10px">Sources: ' + src + '</div>' : (s.generated ? '<div style="font-size:12.5px;color:' + DIM + ';margin-top:10px">Built from Combat fight data</div>' : '')) +
        '</div>';
    });
    if (cov.length) {
      h += '<div style="' + (sums.length ? 'border-top:1px solid ' + GOLD + ';padding-top:14px;' : '') + '">' +
        '<div style="' + H + 'font-size:12px;letter-spacing:2px;color:' + GOLD + ';margin-bottom:4px">MORE COVERAGE</div>';
      cov.forEach(function (c, i) {
        h += '<a href="' + esc(okUrl(c.link)) + '" target="_blank" rel="noopener" style="display:block;text-decoration:none;color:#F5F2EA;padding:10px 0;' + (i ? 'border-top:1px solid ' + LINE : '') + '">' +
          '<div style="font-size:14px;line-height:1.35">' + esc(c.title) + '</div>' +
          '<div style="font-size:12px;color:' + DIM + ';margin-top:3px">' + esc(c.source) + ' &middot; ' + esc(ago(c.date)) + '</div></a>';
      });
      h += '</div>';
    }
    el.innerHTML = h;
  }
  function load(el) {
    var id = el.getAttribute('data-fighter');
    if (!id || el.getAttribute('data-feed') === id) return;
    el.setAttribute('data-feed', id);
    fetch(EP + encodeURIComponent(id)).then(function (r) { return r.ok ? r.json() : null; })
      .then(function (d) { if (d && document.body.contains(el)) render(el, d); }).catch(function () {});
  }
  function scan() { var el = document.getElementById('fpfeed'); if (el) load(el); }
  new MutationObserver(scan).observe(document.documentElement, { childList: true, subtree: true });
  scan();
})();
