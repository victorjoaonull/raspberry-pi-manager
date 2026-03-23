/**
 * Cabeçalhos para fetch com proteção CSRF (token em meta[name="csrf-token"]).
 */
(function () {
  window.piManagerCsrfHeaders = function (base) {
    var h = {};
    if (base) {
      for (var k in base) {
        if (Object.prototype.hasOwnProperty.call(base, k)) h[k] = base[k];
      }
    }
    var el = document.querySelector('meta[name="csrf-token"]');
    if (el && el.content) h["X-CSRF-Token"] = el.content;
    return h;
  };
})();
