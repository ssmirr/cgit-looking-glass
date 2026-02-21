/* cgit.js — theme toggle + minor UX enhancements */
(function () {
  'use strict';

  // ---------------------------------------------------------------
  // Theme toggle
  // ---------------------------------------------------------------
  var STORAGE_KEY = 'cgit-theme';

  function getStoredTheme() {
    try { return localStorage.getItem(STORAGE_KEY); } catch (e) { return null; }
  }

  function setStoredTheme(theme) {
    try { localStorage.setItem(STORAGE_KEY, theme); } catch (e) {}
  }

  function getSystemTheme() {
    if (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) {
      return 'dark';
    }
    return 'light';
  }

  function applyTheme(theme) {
    document.documentElement.setAttribute('data-theme', theme);
  }

  function getCurrentTheme() {
    return document.documentElement.getAttribute('data-theme') || getStoredTheme() || getSystemTheme();
  }

  function toggleTheme() {
    var current = getCurrentTheme();
    var next = current === 'dark' ? 'light' : 'dark';
    applyTheme(next);
    setStoredTheme(next);
  }

  // Apply stored or system theme immediately
  var stored = getStoredTheme();
  if (stored) {
    applyTheme(stored);
  }
  // If no stored preference, leave data-theme unset so CSS media query handles it

  // Listen for system theme changes
  if (window.matchMedia) {
    window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', function (e) {
      // Only react if user hasn't set a manual preference
      if (!getStoredTheme()) {
        // No need to set data-theme; CSS media query handles it
      }
    });
  }

  // ---------------------------------------------------------------
  // Create toggle button on DOM ready
  // ---------------------------------------------------------------
  function createToggleButton() {
    var btn = document.createElement('button');
    btn.className = 'theme-toggle';
    btn.setAttribute('aria-label', 'Toggle dark/light mode');
    btn.setAttribute('title', 'Toggle dark/light mode');
    btn.innerHTML =
      '<span class="icon-sun" aria-hidden="true">&#9728;</span>' +
      '<span class="icon-moon" aria-hidden="true">&#9790;</span>';
    btn.addEventListener('click', toggleTheme);
    document.body.appendChild(btn);
  }

  // ---------------------------------------------------------------
  // Minor UX: external links open in new tab
  // ---------------------------------------------------------------
  function externalLinksNewTab() {
    var links = document.querySelectorAll('a[href^="http"]');
    var host = window.location.host;
    for (var i = 0; i < links.length; i++) {
      if (links[i].hostname !== host) {
        links[i].setAttribute('target', '_blank');
        links[i].setAttribute('rel', 'noopener noreferrer');
      }
    }
  }

  // ---------------------------------------------------------------
  // Keyboard shortcut: press 't' to toggle theme
  // ---------------------------------------------------------------
  function setupKeyboard() {
    document.addEventListener('keydown', function (e) {
      // Don't trigger in input/textarea/select
      if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA' || e.target.tagName === 'SELECT') {
        return;
      }
      if (e.key === 't' && !e.ctrlKey && !e.metaKey && !e.altKey) {
        toggleTheme();
      }
    });
  }

  // ---------------------------------------------------------------
  // Init
  // ---------------------------------------------------------------
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () {
      createToggleButton();
      externalLinksNewTab();
      setupKeyboard();
    });
  } else {
    createToggleButton();
    externalLinksNewTab();
    setupKeyboard();
  }
})();
