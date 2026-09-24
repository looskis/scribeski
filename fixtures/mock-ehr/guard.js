/*
 * guard.js — submit guard, shared by index.html and csp.html.
 *
 * Any <form data-submit-guard> that submits (button click OR implicit Enter-key submission)
 * is stopped, logged loudly, and a red banner (#submit_banner) is shown. Automation reaching
 * this is a bug.
 */
(function () {
  'use strict';

  var MESSAGE = '[mock-ehr] SUBMIT — automation must never reach this';

  function onSubmit(ev) {
    ev.preventDefault();
    console.error(MESSAGE);
    var banner = document.getElementById('submit_banner');
    if (banner) {
      banner.hidden = false;
      banner.textContent = 'SUBMIT BLOCKED — the form submit handler fired. ' +
        'Automation must never reach submit.';
    }
    document.documentElement.setAttribute('data-mock-ehr-submitted', 'true');
  }

  function bindAll() {
    var forms = document.querySelectorAll('form[data-submit-guard]');
    for (var i = 0; i < forms.length; i++) forms[i].addEventListener('submit', onSubmit);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', bindAll);
  } else {
    bindAll();
  }
})();
