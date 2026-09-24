/*
 * controlled.js — a React-style "controlled input", shared by index.html and csp.html.
 *
 * Mirrors React's value tracker (react-dom inputValueTracking):
 *   - an instance-level `value` property whose setter records the "tracked" value and then
 *     calls the prototype setter;
 *   - an `input` listener that IGNORES the event when the DOM value equals the tracked value
 *     (React: "value didn't change, don't fire onChange"), otherwise updates component state;
 *   - a re-render DELAY ms after any write/input that forces the DOM value back to state.
 *
 * Net effect:
 *   el.value = 'AB-114322'                                  -> reads back, then reverts to ''
 *   el.value = 'AB-114322'; el.dispatchEvent(new Event('input', {bubbles: true}))
 *                                                           -> still reverts (event ignored)
 *   nativeSetter.call(el, 'AB-114322'); dispatch 'input'    -> persists
 *   real typing                                             -> persists
 *
 * Auto-binds every <input data-controlled>. No inline script needed (CSP-clean).
 */
(function () {
  'use strict';

  var RENDER_DELAY_MS = 400;
  var proto = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');

  function makeControlled(el) {
    if (el.__mockEhrControlled) return;
    el.__mockEhrControlled = true;

    var state = '';                 // component state (the source of truth)
    var tracked = proto.get.call(el); // value tracker
    var timer = null;

    function scheduleRender() {
      if (timer) clearTimeout(timer);
      timer = setTimeout(render, RENDER_DELAY_MS);
    }

    function render() {
      timer = null;
      if (proto.get.call(el) !== state) {
        proto.set.call(el, state);
      }
      tracked = state;
    }

    Object.defineProperty(el, 'value', {
      configurable: true,
      enumerable: true,
      get: function () {
        return proto.get.call(this);
      },
      set: function (v) {
        tracked = String(v);
        proto.set.call(this, v);
        scheduleRender();
      }
    });

    el.addEventListener('input', function () {
      var dom = proto.get.call(el);
      if (dom === tracked) {
        // Tracker says nothing changed: the "onChange" never fires, state is untouched.
        scheduleRender();
        return;
      }
      tracked = dom;
      state = dom;
      scheduleRender();
    });
  }

  function bindAll(root) {
    var els = (root || document).querySelectorAll('input[data-controlled]');
    for (var i = 0; i < els.length; i++) makeControlled(els[i]);
  }

  window.MockEHRControlled = { makeControlled: makeControlled, bindAll: bindAll };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () { bindAll(document); });
  } else {
    bindAll(document);
  }
})();
