/*
 * ehr.js — page behaviour for index.html: tabs, ARIA combobox, PHQ-9/GAD-7 scoring,
 * "Save draft". The controlled input lives in controlled.js; the submit guard in guard.js.
 * External file only: the page must work under a strict CSP (no inline script/handlers).
 */
(function () {
  'use strict';

  function $(id) { return document.getElementById(id); }

  /* ------------------------------------------------------------------ tabs */
  function initTabs() {
    var tabs = Array.prototype.slice.call(document.querySelectorAll('[role="tab"]'));

    function activate(tab, focus) {
      tabs.forEach(function (t) {
        var selected = t === tab;
        t.setAttribute('aria-selected', selected ? 'true' : 'false');
        t.tabIndex = selected ? 0 : -1;
        var panel = $(t.getAttribute('aria-controls'));
        if (panel) panel.hidden = !selected;
      });
      if (focus) tab.focus();
    }

    tabs.forEach(function (tab, i) {
      tab.addEventListener('click', function () { activate(tab, false); });
      tab.addEventListener('keydown', function (ev) {
        var next = null;
        if (ev.key === 'ArrowRight') next = tabs[(i + 1) % tabs.length];
        else if (ev.key === 'ArrowLeft') next = tabs[(i - 1 + tabs.length) % tabs.length];
        else if (ev.key === 'Home') next = tabs[0];
        else if (ev.key === 'End') next = tabs[tabs.length - 1];
        if (next) { ev.preventDefault(); activate(next, true); }
      });
    });
  }

  /* -------------------------------------------------------------- combobox */
  var OPEN_DELAY_MS = 60;

  function initCombobox() {
    var trigger = $('language_combo');
    var listbox = $('language_listbox');
    if (!trigger || !listbox) return;
    var options = Array.prototype.slice.call(listbox.querySelectorAll('[role="option"]'));
    var openTimer = null;

    function isOpen() { return trigger.getAttribute('aria-expanded') === 'true'; }

    function open() {
      if (openTimer) return;
      // Async on purpose: automation must wait for the listbox, not assume it is there.
      openTimer = setTimeout(function () {
        openTimer = null;
        listbox.hidden = false;
        trigger.setAttribute('aria-expanded', 'true');
        var sel = listbox.querySelector('[aria-selected="true"]') || options[0];
        if (sel && document.activeElement === trigger) sel.focus();
      }, OPEN_DELAY_MS);
    }

    function close(refocus) {
      if (openTimer) { clearTimeout(openTimer); openTimer = null; }
      listbox.hidden = true;
      trigger.setAttribute('aria-expanded', 'false');
      if (refocus) trigger.focus();
    }

    function select(opt) {
      options.forEach(function (o) {
        o.setAttribute('aria-selected', o === opt ? 'true' : 'false');
      });
      trigger.textContent = opt.textContent;
      trigger.setAttribute('data-value', opt.getAttribute('data-value'));
      close(true);
      trigger.dispatchEvent(new CustomEvent('combochange', {
        bubbles: true, detail: { value: opt.getAttribute('data-value') }
      }));
    }

    trigger.addEventListener('click', function () {
      if (isOpen()) close(false); else open();
    });
    trigger.addEventListener('keydown', function (ev) {
      if (ev.key === 'Enter' || ev.key === ' ' || ev.key === 'ArrowDown') {
        ev.preventDefault();
        if (!isOpen()) open();
      } else if (ev.key === 'Escape') {
        close(true);
      }
    });

    options.forEach(function (opt, i) {
      opt.addEventListener('click', function (ev) {
        ev.stopPropagation();
        select(opt);
      });
      opt.addEventListener('keydown', function (ev) {
        if (ev.key === 'ArrowDown') { ev.preventDefault(); (options[i + 1] || opt).focus(); }
        else if (ev.key === 'ArrowUp') { ev.preventDefault(); (options[i - 1] || opt).focus(); }
        else if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); select(opt); }
        else if (ev.key === 'Escape' || ev.key === 'Tab') { close(ev.key === 'Escape'); }
      });
    });

    document.addEventListener('click', function (ev) {
      if (!isOpen()) return;
      if (trigger.contains(ev.target) || listbox.contains(ev.target)) return;
      close(false);
    });
  }

  /* --------------------------------------------------------------- scoring */
  var INSTRUMENTS = {
    phq9: {
      items: 9,
      bands: [
        [4, 'MINIMAL', 'Minimal'],
        [9, 'MILD', 'Mild'],
        [14, 'MODERATE', 'Moderate'],
        [19, 'MODERATELY_SEVERE', 'Moderately severe'],
        [27, 'SEVERE', 'Severe']
      ]
    },
    gad7: {
      items: 7,
      bands: [
        [4, 'MINIMAL', 'Minimal'],
        [9, 'MILD', 'Mild'],
        [14, 'MODERATE', 'Moderate'],
        [21, 'SEVERE', 'Severe']
      ]
    }
  };

  function score(form, key) {
    var inst = INSTRUMENTS[key];
    var total = 0;
    var answered = 0;
    for (var i = 1; i <= inst.items; i++) {
      var checked = form.querySelector('input[type="radio"][name="' + key + '_' + i + '"]:checked');
      if (checked) { answered++; total += parseInt(checked.value, 10); }
    }
    var scoreEl = $(key + '_score');
    var sevEl = $(key + '_severity');
    var display = $(key + '_total');
    if (answered < inst.items) {
      scoreEl.value = '';
      sevEl.value = '';
      display.textContent = 'Total: — (incomplete)';
      display.className = 'score-total';
      return;
    }
    var band = inst.bands[inst.bands.length - 1];
    for (var b = 0; b < inst.bands.length; b++) {
      if (total <= inst.bands[b][0]) { band = inst.bands[b]; break; }
    }
    scoreEl.value = String(total);
    sevEl.value = band[1];
    display.textContent = 'Total: ' + total + ' · ' + band[2];
    display.className = 'score-total complete sev-' + band[1].toLowerCase();
  }

  function initScoring() {
    var form = $('intake_form');
    if (!form) return;
    function recompute(ev) {
      var t = ev && ev.target;
      if (t && !(t.type === 'radio' && /^(phq9|gad7)_\d$/.test(t.name))) return;
      score(form, 'phq9');
      score(form, 'gad7');
    }
    form.addEventListener('change', recompute);
    form.addEventListener('input', recompute);
    score(form, 'phq9');
    score(form, 'gad7');
  }

  /* ----------------------------------------------------------- save draft */
  function pad(n) { return (n < 10 ? '0' : '') + n; }

  function initSaveDraft() {
    var btn = $('btn_save_draft');
    if (!btn) return;
    btn.addEventListener('click', function () {
      // Harmless: updates the header timestamp only. Nothing leaves the page.
      var d = new Date();
      var h = d.getHours();
      var ampm = h >= 12 ? 'PM' : 'AM';
      h = h % 12 || 12;
      $('meta_last_saved').textContent = pad(d.getMonth() + 1) + '/' + pad(d.getDate()) + '/' +
        d.getFullYear() + ' ' + h + ':' + pad(d.getMinutes()) + ' ' + ampm;
      $('draft_status').textContent = 'Draft saved (local only).';
    });
  }

  /* ------------------------------------------------------------- autosave */
  // Opt-in with ?autosave=1: posts on every change, like EHRs that autosave drafts. Lets
  // tests prove the filler notices page traffic. The endpoint 404s; that is fine.
  function initAutosave() {
    if (!/[?&]autosave=1(&|$)/.test(location.search)) return;
    document.addEventListener('change', function (ev) {
      var name = (ev.target && (ev.target.name || ev.target.id)) || 'unknown';
      fetch('autosave', { method: 'POST', body: 'changed=' + encodeURIComponent(name) })
        .catch(function () {});
    });
  }

  function init() {
    initTabs();
    initCombobox();
    initScoring();
    initSaveDraft();
    initAutosave();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
