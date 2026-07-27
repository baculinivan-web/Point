import Foundation

/// The JavaScript half of the agent driver.
///
/// Everything here runs in a dedicated `WKContentWorld`, so the page cannot
/// read, shadow, or tamper with it — which matters because the agent operates
/// with the person's live logins and the page is untrusted input.
///
/// The bootstrap is idempotent and is prepended to every call rather than
/// installed as a `WKUserScript`: a page can navigate between two agent steps,
/// and re-declaring on demand is simpler than tracking which document is
/// currently loaded in each frame.
enum PageAgentScript {
    static let bootstrap = #"""
    (() => {
      if (globalThis.__pointAgent) { return; }

      const INTERACTIVE = [
        'a[href]', 'button', 'input', 'select', 'textarea', 'summary',
        '[role="button"]', '[role="link"]', '[role="checkbox"]',
        '[role="radio"]', '[role="tab"]', '[role="menuitem"]',
        '[role="menuitemcheckbox"]', '[role="switch"]', '[role="textbox"]',
        '[role="combobox"]', '[role="option"]', '[role="searchbox"]',
        '[contenteditable=""]', '[contenteditable="true"]',
        '[onclick]', '[tabindex]'
      ].join(',');

      const agent = { nodes: [] };

      function textOf(node) {
        if (!node) { return ''; }
        const raw = node.innerText || node.textContent || '';
        return raw.replace(/\s+/g, ' ').trim();
      }

      function clip(value, max) {
        if (!value) { return ''; }
        return value.length > max ? value.slice(0, max) + '…' : value;
      }

      function accessibleName(el) {
        const aria = el.getAttribute('aria-label');
        if (aria && aria.trim()) { return aria.trim(); }

        const labelledBy = el.getAttribute('aria-labelledby');
        if (labelledBy) {
          const parts = labelledBy.split(/\s+/)
            .map((id) => el.ownerDocument.getElementById(id))
            .filter(Boolean)
            .map(textOf)
            .filter(Boolean);
          if (parts.length) { return parts.join(' '); }
        }

        if (el.id && el.ownerDocument.querySelector) {
          try {
            const label = el.ownerDocument.querySelector(
              'label[for="' + CSS.escape(el.id) + '"]'
            );
            const labelText = textOf(label);
            if (labelText) { return labelText; }
          } catch (ignored) { /* malformed id */ }
        }

        const wrapping = el.closest ? el.closest('label') : null;
        if (wrapping && wrapping !== el) {
          const wrappingText = textOf(wrapping);
          if (wrappingText) { return wrappingText; }
        }

        const own = textOf(el);
        if (own) { return own; }

        for (const attribute of ['placeholder', 'title', 'alt', 'name']) {
          const value = el.getAttribute(attribute);
          if (value && value.trim()) { return value.trim(); }
        }
        return '';
      }

      function roleOf(el) {
        const explicit = el.getAttribute('role');
        if (explicit && explicit.trim()) {
          return explicit.trim().toLowerCase();
        }
        const tag = el.tagName.toLowerCase();
        if (tag === 'a') { return 'link'; }
        if (tag === 'button' || tag === 'summary') { return 'button'; }
        if (tag === 'select') { return 'combobox'; }
        if (tag === 'textarea') { return 'textbox'; }
        if (tag === 'input') {
          const type = (el.getAttribute('type') || 'text').toLowerCase();
          if (type === 'checkbox' || type === 'radio') { return type; }
          if (type === 'password') { return 'password'; }
          if (type === 'file') { return 'file'; }
          if (['submit', 'button', 'image', 'reset'].includes(type)) {
            return 'button';
          }
          return 'textbox';
        }
        if (el.isContentEditable) { return 'textbox'; }
        return 'generic';
      }

      /// True when the control lives in a search form. Submitting a search is
      /// harmless and must not be treated as an irreversible form submission.
      function inSearchContext(el) {
        const type = (el.getAttribute('type') || '').toLowerCase();
        const role = (el.getAttribute('role') || '').toLowerCase();
        if (type === 'search' || role === 'searchbox' || role === 'search') {
          return true;
        }
        const form = el.closest ? el.closest('form') : null;
        if (!form) { return false; }
        if ((form.getAttribute('role') || '').toLowerCase() === 'search') {
          return true;
        }
        if (form.querySelector('input[type="search"], [role="searchbox"]')) {
          return true;
        }
        // Nothing but a text box and a button, named like a search: the shape
        // every site's search form has.
        const named = form.querySelector(
          'input[name="q"], input[name="query"], input[name="search"], ' +
          'input[name="s"], input[name="keyword"], input[name="keywords"]'
        );
        return !!named;
      }

      /// A field submitted with Enter has no useful action label of its own.
      /// Carry a small amount of owning-form context so native code can tell a
      /// harmless search/filter from a final "Place order" submission.
      function formIntentOf(el) {
        const form = el.form || (el.closest ? el.closest('form') : null);
        if (!form) { return ''; }
        const parts = [
          form.getAttribute('aria-label'),
          form.getAttribute('name'),
          form.getAttribute('action')
        ].filter(Boolean);
        let submitSelector =
          'button[type="submit"], button:not([type]), input[type="submit"], ' +
          'input[type="image"]';
        let submitter = el.matches && el.matches(submitSelector)
          ? el
          : form.querySelector(submitSelector);
        try {
          if (submitter) {
            const label = accessibleName(submitter) || submitter.value || '';
            if (label) { parts.push(label); }
          }
        } catch (ignored) {
          // Form metadata above is still useful when a malformed page makes
          // inspecting its default submitter fail.
        }
        return clip(parts.join(' '), 300);
      }

      function isRendered(el, style) {
        if (!style) { return false; }
        if (style.visibility === 'hidden' || style.display === 'none') {
          return false;
        }
        if (parseFloat(style.opacity || '1') < 0.05) { return false; }
        if (el.getAttribute('aria-hidden') === 'true') { return false; }
        return true;
      }

      /// Walks a document (and any same-origin iframe) gathering interactive
      /// elements with viewport-relative geometry.
      ///
      /// Cross-origin iframes are unreachable from here; the driver reports
      /// them rather than pretending the page has no content inside them.
      function collect(doc, offsetX, offsetY, depth, out, limit, blocked) {
        let candidates;
        try {
          candidates = doc.querySelectorAll(INTERACTIVE);
        } catch (ignored) {
          return;
        }

        for (const el of candidates) {
          if (out.length >= limit) { return; }
          if (el.getAttribute('tabindex') === '-1' &&
              !el.matches('a[href],button,input,select,textarea')) {
            continue;
          }

          let style;
          try {
            style = el.ownerDocument.defaultView.getComputedStyle(el);
          } catch (ignored) { continue; }
          if (!isRendered(el, style)) { continue; }

          const rect = el.getBoundingClientRect();
          if (rect.width < 2 || rect.height < 2) { continue; }

          const x = rect.left + offsetX;
          const y = rect.top + offsetY;
          const view = doc.defaultView;
          const inViewport = y + rect.height > 0 && x + rect.width > 0 &&
            y < (view.innerHeight || 0) && x < (view.innerWidth || 0);

          const role = roleOf(el);
          const name = clip(accessibleName(el), 120);
          if (!name && role === 'generic') { continue; }

          const index = agent.nodes.length;
          agent.nodes.push({ el: el, ox: offsetX, oy: offsetY });

          out.push({
            ref: 'e' + index,
            role: role,
            name: name,
            value: clip(
              role === 'password' ? '' : (el.value == null ? '' : String(el.value)),
              80
            ),
            placeholder: el.getAttribute('placeholder') || '',
            inputType: (el.getAttribute('type') || '').toLowerCase(),
            autocomplete: (el.getAttribute('autocomplete') || '').toLowerCase(),
            href: el.tagName.toLowerCase() === 'a' ? (el.href || '') : '',
            formAction: el.getAttribute('formaction') ||
              (el.form ? (el.form.getAttribute('action') || '') : ''),
            formIntent: formIntentOf(el),
            isSubmit: el.type === 'submit' ||
              (el.tagName.toLowerCase() === 'button' &&
               (el.getAttribute('type') || 'submit') === 'submit' &&
               !!el.form),
            isSearchContext: inSearchContext(el),
            hasDownload: el.hasAttribute('download'),
            disabled: !!el.disabled || el.getAttribute('aria-disabled') === 'true',
            checked: el.checked === true,
            inViewport: inViewport,
            inFrame: depth > 0,
            x: x, y: y, w: rect.width, h: rect.height
          });
        }

        if (depth >= 3) { return; }
        for (const frame of doc.querySelectorAll('iframe,frame')) {
          if (out.length >= limit) { return; }
          const frameRect = frame.getBoundingClientRect();
          if (frameRect.width < 8 || frameRect.height < 8) { continue; }
          let inner = null;
          try { inner = frame.contentDocument; } catch (ignored) { inner = null; }
          if (!inner) {
            blocked.push(frame.getAttribute('src') || 'cross-origin frame');
            continue;
          }
          collect(
            inner,
            offsetX + frameRect.left,
            offsetY + frameRect.top,
            depth + 1,
            out,
            limit,
            blocked
          );
        }
      }

      function readableText(limit) {
        const root = document.querySelector('main') ||
          document.querySelector('article') || document.body;
        if (!root) { return ''; }
        return (root.innerText || '')
          .replace(/[ \t]+/g, ' ')
          .replace(/\n{3,}/g, '\n\n')
          .trim()
          .slice(0, limit);
      }

      agent.snapshot = function (maxElements, textLimit) {
        agent.nodes = [];
        const elements = [];
        const blocked = [];
        collect(document, 0, 0, 0, elements, maxElements, blocked);
        return JSON.stringify({
          url: location.href,
          title: document.title || '',
          scrollY: window.scrollY,
          scrollHeight: Math.max(
            document.body ? document.body.scrollHeight : 0,
            document.documentElement ? document.documentElement.scrollHeight : 0
          ),
          viewportHeight: window.innerHeight,
          readyState: document.readyState,
          text: readableText(textLimit),
          blockedFrames: blocked.slice(0, 5),
          elements: elements
        });
      };

      agent.entry = function (ref) {
        const index = parseInt(String(ref).replace(/^e/, ''), 10);
        if (!Number.isInteger(index)) { return null; }
        const entry = agent.nodes[index];
        if (!entry || !entry.el) { return null; }
        if (!entry.el.isConnected) { return null; }
        return entry;
      };

      /// Scrolls the element into view and reports where it landed, so the
      /// native side can aim a real click at it.
      agent.locate = function (ref) {
        const entry = agent.entry(ref);
        if (!entry) {
          return JSON.stringify({ ok: false, reason: 'stale' });
        }
        try {
          entry.el.scrollIntoView({ block: 'center', inline: 'center' });
        } catch (ignored) { /* detached layout */ }
        const rect = entry.el.getBoundingClientRect();
        const x = rect.left + entry.ox + rect.width / 2;
        const y = rect.top + entry.oy + rect.height / 2;
        const onScreen = x >= 0 && y >= 0 &&
          x <= window.innerWidth && y <= window.innerHeight &&
          rect.width >= 1 && rect.height >= 1;
        return JSON.stringify({
          ok: onScreen,
          reason: onScreen ? '' : 'offscreen',
          x: x, y: y,
          left: rect.left + entry.ox,
          top: rect.top + entry.oy,
          width: rect.width,
          height: rect.height,
          viewportWidth: window.innerWidth,
          viewportHeight: window.innerHeight,
          name: accessibleName(entry.el),
          role: roleOf(entry.el)
        });
      };

      agent.domClick = function (ref) {
        const entry = agent.entry(ref);
        if (!entry) { return JSON.stringify({ ok: false, reason: 'stale' }); }
        try {
          entry.el.focus({ preventScroll: true });
        } catch (ignored) { /* not focusable */ }
        entry.el.click();
        return JSON.stringify({ ok: true });
      };

      function setNativeValue(el, value) {
        const prototype = el instanceof HTMLTextAreaElement
          ? HTMLTextAreaElement.prototype
          : HTMLInputElement.prototype;
        const descriptor = Object.getOwnPropertyDescriptor(prototype, 'value');
        if (descriptor && descriptor.set) {
          descriptor.set.call(el, value);
        } else {
          el.value = value;
        }
      }

      /// Types into a field the way a framework-backed page expects: the value
      /// goes through the native setter, then input/change fire, so React and
      /// friends see the update instead of silently reverting it.
      agent.fill = function (ref, text, replace) {
        const entry = agent.entry(ref);
        if (!entry) { return JSON.stringify({ ok: false, reason: 'stale' }); }
        const el = entry.el;
        if (el.disabled || el.readOnly) {
          return JSON.stringify({ ok: false, reason: 'readonly' });
        }
        try {
          el.scrollIntoView({ block: 'center' });
          el.focus({ preventScroll: true });
        } catch (ignored) { /* not focusable */ }

        if (el.isContentEditable) {
          if (replace) { el.textContent = ''; }
          el.textContent = (el.textContent || '') + text;
        } else {
          const next = replace ? text : String(el.value || '') + text;
          setNativeValue(el, next);
        }

        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        const rect = el.getBoundingClientRect();
        return JSON.stringify({
          ok: true,
          left: rect.left + entry.ox,
          top: rect.top + entry.oy,
          width: rect.width,
          height: rect.height,
          viewportWidth: window.innerWidth,
          viewportHeight: window.innerHeight
        });
      };

      agent.selectOption = function (ref, label) {
        const entry = agent.entry(ref);
        if (!entry) { return JSON.stringify({ ok: false, reason: 'stale' }); }
        const el = entry.el;
        if (!el.options) {
          return JSON.stringify({ ok: false, reason: 'not-a-select' });
        }
        const wanted = String(label).trim().toLowerCase();
        for (const option of el.options) {
          const text = (option.label || option.textContent || '').trim();
          if (text.toLowerCase() === wanted ||
              String(option.value).toLowerCase() === wanted) {
            el.value = option.value;
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return JSON.stringify({ ok: true, selected: text });
          }
        }
        const available = Array.from(el.options)
          .map((option) => (option.label || option.textContent || '').trim())
          .slice(0, 40);
        return JSON.stringify({
          ok: false, reason: 'no-such-option', available: available
        });
      };

      agent.pressEnter = function (ref) {
        const entry = ref ? agent.entry(ref) : null;
        const target = entry ? entry.el : document.activeElement;
        if (!target) { return JSON.stringify({ ok: false, reason: 'no-target' }); }
        const options = {
          key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true
        };
        target.dispatchEvent(new KeyboardEvent('keydown', options));
        target.dispatchEvent(new KeyboardEvent('keypress', options));
        target.dispatchEvent(new KeyboardEvent('keyup', options));
        if (target.form && typeof target.form.requestSubmit === 'function') {
          target.form.requestSubmit();
        }
        return JSON.stringify({ ok: true });
      };

      agent.scroll = function (dx, dy) {
        const before = window.scrollY;
        window.scrollBy({ left: dx, top: dy, behavior: 'instant' });
        return JSON.stringify({
          ok: true,
          from: before,
          to: window.scrollY,
          scrollHeight: Math.max(
            document.body ? document.body.scrollHeight : 0,
            document.documentElement ? document.documentElement.scrollHeight : 0
          ),
          viewportHeight: window.innerHeight
        });
      };

      agent.readyState = function () {
        return JSON.stringify({
          readyState: document.readyState,
          url: location.href,
          title: document.title || ''
        });
      };

      globalThis.__pointAgent = agent;
    })();
    """#

    /// Wraps a call so it always runs against a freshly-ensured bootstrap.
    static func call(_ expression: String) -> String {
        bootstrap + "\nreturn " + expression + ";"
    }
}
