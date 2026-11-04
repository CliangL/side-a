/* Keep this file ES5: it must run before the main UI on older car WebViews. */
(function () {
  'use strict';
  var ready = false;
  var failed = false;
  function report(kind) {
    if (ready || failed) return;
    failed = true;
    var safeKind = kind === 'script' || kind === 'runtime' ? kind : 'startup';
    if (window.SideA && typeof window.SideA.uiFailed === 'function') {
      window.SideA.uiFailed(safeKind);
    }
  }
  window.sideaBoot = {
    ready: function () {
      if (ready || failed) return;
      ready = true;
      if (window.SideA && typeof window.SideA.uiReady === 'function') window.SideA.uiReady();
    },
    failed: report
  };
  window.addEventListener('error', function (event) {
    if (event.target && event.target.tagName === 'SCRIPT') report('script');
    else if (event.target === window) report('runtime');
  }, true);
  window.addEventListener('unhandledrejection', function () { report('runtime'); });

  if (window.Promise && !Promise.prototype.finally) {
    Promise.prototype.finally = function (callback) {
      var Constructor = this.constructor || Promise;
      if (typeof callback !== 'function') return this.then(callback, callback);
      return this.then(function (value) {
        return Constructor.resolve(callback()).then(function () { return value; });
      }, function (reason) {
        return Constructor.resolve(callback()).then(function () { throw reason; });
      });
    };
  }
  if (window.Element && !Element.prototype.scrollTo) {
    Element.prototype.scrollTo = function (left, top) {
      if (typeof left === 'object' && left) {
        if (left.left != null) this.scrollLeft = left.left;
        if (left.top != null) this.scrollTop = left.top;
      } else {
        this.scrollLeft = left || 0;
        this.scrollTop = top || 0;
      }
    };
  }
  // Grid gap support alone does not imply flex gap support (older Android WebView).
  document.addEventListener('DOMContentLoaded', function () {
    var probe = document.createElement('div');
    probe.style.cssText = 'position:absolute;left:-9999px;top:-9999px;display:flex;flex-direction:column;row-gap:1px;';
    probe.appendChild(document.createElement('div')).style.height = '1px';
    probe.appendChild(document.createElement('div')).style.height = '1px';
    document.body.appendChild(probe);
    if (probe.scrollHeight !== 3) document.documentElement.classList.add('no-flex-gap');
    document.body.removeChild(probe);
  });
}());
