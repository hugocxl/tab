import Foundation
import TabClient
import WebKit

/// The scripts agents drive pages with. The runtime lives in its own content
/// world, so pages can't see or replace it, and keeps the element refs
/// (`@e1`) that snapshots print. Log capture runs in the page's world, where
/// `console`, `fetch` and `XMLHttpRequest` are.
public enum BrowserAgentScripts {
    /// The world the runtime and element commands run in.
    @MainActor static let world = WKContentWorld.world(name: "TabAgent")
    /// The message handler log capture posts to.
    static let logHandler = "tabAgentLog"
    /// The message handler frames answer `linkFrames` on, in the runtime's world.
    static let frameHandler = "tabAgentFrame"

    /// A runtime call: `body` sees the runtime as `A` and returns a value.
    /// Without a runtime the page answers `{"missing": true}`; a thrown
    /// error comes back as `{"error": message}`.
    static func call(_ body: String) -> String {
        """
        const A = globalThis.__tabAgent;
        if (!A) return { missing: true };
        try {
          const value = await (async () => {
        \(body)
          })();
          return { value: value === undefined ? null : value, next: A.next() };
        } catch (error) {
          return { error: String(error && error.message || error), next: A.next() };
        }
        """
    }

    /// Installs the runtime, numbering new refs from `start` so a ref from an
    /// earlier page never names an element of this one. A frame's runtime
    /// puts its frame in front of its refs: `f2e5`.
    static func install(start: Int, frame: Int? = nil) -> String {
        runtime.replacingOccurrences(of: "__TAB_START__", with: String(max(start, 1)))
            .replacingOccurrences(of: "__TAB_PREFIX__", with: frame.map { "'f\($0)'" } ?? "''") + "\nreturn true;"
    }

    /// `ref` as the runtime names it: `@e3`, `ref=e3` and `e3` all name `e3`,
    /// and `@f2e5` names `e5` of frame 2.
    public static func refId(_ target: String) -> String? {
        var text = target.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("@") { text.removeFirst() } else if text.hasPrefix("ref=") { text.removeFirst(4) }
        var rest = Substring(text)
        if rest.first == "f" {
            rest = rest.dropFirst()
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty else { return nil }
            rest = rest.dropFirst(digits.count)
        }
        guard rest.count > 1, rest.first == "e", rest.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }
        return text
    }

    /// The frame a ref belongs to: 2 for `@f2e5`, `nil` for the page's own refs.
    public static func refFrame(_ target: String) -> Int? {
        guard let id = refId(target), id.first == "f" else { return nil }
        return Int(id.dropFirst().prefix { $0.isNumber })
    }

    /// Listens, in every frame but the top one, for the token a parent's
    /// `linkFrames` sends, and hands it to the app with the frame, so the
    /// app can reach a cross-origin frame's elements.
    static let frameListener = #"""
    (() => {
    if (window === window.top) return;
    addEventListener('message', event => {
      const data = event.data;
      if (!data || typeof data.__tabAgentFrame !== 'string') return;
      try { window.webkit.messageHandlers.tabAgentFrame.postMessage({ token: data.__tabAgentFrame, url: location.href }); }
      catch (error) {}
    }, true);
    })();
    """#

    static let runtime = #"""
    (() => {
    if (globalThis.__tabAgent) return;
    let counter = __TAB_START__;
    const PREFIX = __TAB_PREFIX__;
    const refs = new Map();
    const ids = new WeakMap();
    const INTERACTIVE = new Set(['button', 'link', 'textbox', 'searchbox', 'combobox', 'listbox', 'checkbox', 'radio',
      'slider', 'spinbutton', 'switch', 'tab', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'option', 'treeitem',
      'clickable']);
    const STRUCTURE = new Set(['heading', 'img', 'list', 'listitem', 'navigation', 'main', 'banner', 'contentinfo',
      'complementary', 'form', 'region', 'article', 'dialog', 'alertdialog', 'alert', 'status', 'table', 'row', 'cell',
      'columnheader', 'rowheader', 'group', 'tablist', 'tabpanel', 'menu', 'menubar', 'toolbar', 'tree', 'grid',
      'progressbar', 'meter', 'iframe', 'figure', 'search', 'radiogroup', 'log', 'marquee', 'timer', 'tooltip', 'feed']);
    const NAME_FROM_CONTENT = new Set(['button', 'link', 'heading', 'tab', 'menuitem', 'menuitemcheckbox',
      'menuitemradio', 'option', 'cell', 'columnheader', 'rowheader', 'checkbox', 'radio', 'switch', 'treeitem',
      'tooltip', 'clickable']);
    const SKIP = new Set(['script', 'style', 'noscript', 'template', 'head', 'meta', 'link', 'title', 'base']);
    const LINE_LIMIT = 2000;
    const clean = (value, limit = 120) => {
      const text = String(value ?? '').replace(/\s+/g, ' ').trim();
      return text.length > limit ? text.slice(0, limit - 1) + '…' : text;
    };
    const quote = value => JSON.stringify(value);

    const refOf = el => {
      let id = ids.get(el);
      if (!id) {
        id = PREFIX + 'e' + counter++;
        ids.set(el, id);
        refs.set(id, new WeakRef(el));
        if (refs.size > 20000) for (const [key, ref] of refs) if (!ref.deref()) refs.delete(key);
      }
      return id;
    };
    const refName = target => {
      const match = /^(?:@|ref=)?((?:f\d+)?e\d+)$/.exec(String(target).trim());
      return match ? match[1] : null;
    };
    const find = target => {
      const id = refName(target);
      if (id) {
        const el = refs.get(id)?.deref();
        if (!el) throw new Error('unknown ref @' + id + ': it is from an earlier page or was never printed; run snapshot again');
        if (!el.isConnected) throw new Error('stale ref @' + id + ': the element is gone from the page; run snapshot again');
        return el;
      }
      return queryAll(target, true)[0] || null;
    };
    // The documents and open shadow roots of the page, its same-origin frames included.
    const scopes = () => {
      const out = [];
      const visit = root => {
        out.push(root);
        for (const el of root.querySelectorAll('*')) {
          if (el.shadowRoot) visit(el.shadowRoot);
          const tag = el.localName;
          if (tag === 'iframe' || tag === 'frame') {
            let doc = null;
            try { doc = el.contentDocument; } catch (error) { doc = null; }
            if (doc && doc.documentElement) visit(doc);
          }
        }
      };
      visit(document);
      return out;
    };
    // The elements a CSS selector matches: in the page first, then in its
    // shadow roots and same-origin frames; `first` stops at the first match.
    const queryAll = (selector, first) => {
      let found;
      try { found = first ? [document.querySelector(selector)].filter(Boolean) : Array.from(document.querySelectorAll(selector)); }
      catch (error) { throw new Error('invalid selector ' + quote(String(selector))); }
      if (first && found.length) return found;
      for (const scope of scopes().slice(1)) {
        if (first) {
          const el = scope.querySelector(selector);
          if (el) return [el];
        } else {
          found.push(...scope.querySelectorAll(selector));
        }
      }
      return found;
    };

    const tagOf = el => el.localName || '';
    const inputType = el => (el.getAttribute('type') || 'text').toLowerCase();
    const implicitRole = el => {
      const tag = tagOf(el);
      switch (tag) {
        case 'a': case 'area': return el.hasAttribute('href') ? 'link' : null;
        case 'button': case 'summary': return 'button';
        case 'input': {
          const type = inputType(el);
          if (['button', 'submit', 'reset', 'image', 'file'].includes(type)) return 'button';
          if (type === 'checkbox' || type === 'radio') return type;
          if (type === 'range') return 'slider';
          if (type === 'number') return 'spinbutton';
          if (type === 'hidden') return null;
          if (el.hasAttribute('list')) return 'combobox';
          return type === 'search' ? 'searchbox' : 'textbox';
        }
        case 'select': return el.multiple || el.size > 1 ? 'listbox' : 'combobox';
        case 'option': return 'option';
        case 'textarea': return 'textbox';
        case 'h1': case 'h2': case 'h3': case 'h4': case 'h5': case 'h6': return 'heading';
        case 'img': return el.getAttribute('alt') === '' ? null : 'img';
        case 'nav': return 'navigation';
        case 'main': return 'main';
        case 'header': return el.closest('article, aside, main, nav, section') ? null : 'banner';
        case 'footer': return el.closest('article, aside, main, nav, section') ? null : 'contentinfo';
        case 'aside': return 'complementary';
        case 'form': return 'form';
        case 'search': return 'search';
        case 'section': return el.hasAttribute('aria-label') || el.hasAttribute('aria-labelledby') ? 'region' : null;
        case 'article': return 'article';
        case 'dialog': return 'dialog';
        case 'ul': case 'ol': case 'menu': return 'list';
        case 'li': return 'listitem';
        case 'table': return 'table';
        case 'tr': return 'row';
        case 'td': return 'cell';
        case 'th': return el.getAttribute('scope') === 'row' ? 'rowheader' : 'columnheader';
        case 'progress': return 'progressbar';
        case 'meter': return 'meter';
        case 'fieldset': case 'details': return 'group';
        case 'figure': return 'figure';
        case 'iframe': case 'frame': return 'iframe';
      }
      if (el.isContentEditable && !(el.parentElement && el.parentElement.isContentEditable)) return 'textbox';
      return null;
    };
    const roleOf = el => {
      const explicit = (el.getAttribute('role') || '').trim().split(/\s+/)[0].toLowerCase();
      if (explicit === 'none' || explicit === 'presentation') return null;
      return explicit || implicitRole(el);
    };
    const textOf = el => {
      const text = el.innerText;
      return text === undefined ? el.textContent : text;
    };
    const nameOf = (el, role) => {
      const doc = el.ownerDocument;
      const by = el.getAttribute('aria-labelledby');
      if (by) {
        const text = clean(by.split(/\s+/).map(id => { const node = doc.getElementById(id); return node ? textOf(node) : ''; }).join(' '));
        if (text) return text;
      }
      const aria = clean(el.getAttribute('aria-label'));
      if (aria) return aria;
      const tag = tagOf(el);
      if (tag === 'input' && ['button', 'submit', 'reset'].includes(inputType(el))) {
        return clean(el.value || { submit: 'Submit', reset: 'Reset' }[inputType(el)] || '');
      }
      if (el.labels && el.labels.length) {
        const text = clean(Array.from(el.labels).map(textOf).join(' '));
        if (text) return text;
      }
      if (tag === 'img' || tag === 'area' || (tag === 'input' && inputType(el) === 'image')) {
        const alt = clean(el.getAttribute('alt'));
        if (alt) return alt;
      }
      if (tag === 'fieldset') { const legend = el.querySelector(':scope > legend'); if (legend) return clean(textOf(legend)); }
      if (tag === 'table') { const caption = el.querySelector(':scope > caption'); if (caption) return clean(textOf(caption)); }
      if (tag === 'figure') { const caption = el.querySelector(':scope > figcaption'); if (caption) return clean(textOf(caption)); }
      if (tag === 'iframe' || tag === 'frame') return clean(el.getAttribute('title') || el.getAttribute('name'));
      if (NAME_FROM_CONTENT.has(role)) {
        let text = clean(textOf(el));
        if (!text) {
          const image = el.querySelector('img[alt], svg[aria-label], [aria-label]');
          if (image) text = clean(image.getAttribute('alt') || image.getAttribute('aria-label'));
        }
        if (text) return text;
      }
      return clean(el.getAttribute('title') || el.getAttribute('placeholder') || '');
    };
    const isDisabled = el => Boolean(el.disabled) || el.getAttribute('aria-disabled') === 'true'
      || Boolean(el.closest && el.closest('fieldset[disabled]') && tagOf(el) !== 'legend' && 'disabled' in el);
    const isEditable = el => {
      const tag = tagOf(el);
      if (tag === 'textarea') return !el.readOnly && !el.disabled;
      if (tag === 'input') {
        return !['button', 'submit', 'reset', 'image', 'file', 'checkbox', 'radio', 'range', 'color', 'hidden'].includes(inputType(el))
          && !el.readOnly && !el.disabled;
      }
      return el.isContentEditable;
    };
    const valueOf = (el, role) => {
      const tag = tagOf(el);
      if (tag === 'select') return clean(Array.from(el.selectedOptions).map(option => option.textContent).join(', '));
      if (tag === 'input' || tag === 'textarea') {
        if (['checkbox', 'radio', 'button', 'submit', 'reset', 'image', 'file'].includes(inputType(el)) && tag === 'input') return null;
        if (tag === 'input' && inputType(el) === 'password') return el.value ? '••••' : '';
        return clean(el.value, 200);
      }
      if (role === 'textbox' && el.isContentEditable) return clean(el.textContent, 200);
      const aria = el.getAttribute('aria-valuetext') || el.getAttribute('aria-valuenow');
      return aria === null ? null : clean(aria);
    };
    const states = (el, role, options) => {
      const out = [];
      const tag = tagOf(el);
      if (role === 'heading') {
        const level = el.getAttribute('aria-level') || (/^h([1-6])$/.exec(tag) || [])[1];
        if (level) out.push('level=' + level);
      }
      const checked = tag === 'input' && (el.type === 'checkbox' || el.type === 'radio') ? el.checked
        : el.getAttribute('aria-checked') === 'true' ? true : el.getAttribute('aria-checked') === 'mixed' ? 'mixed' : null;
      if (checked === true) out.push('checked');
      else if (checked === 'mixed') out.push('mixed');
      if (isDisabled(el) && INTERACTIVE.has(role)) out.push('disabled');
      const expanded = el.getAttribute('aria-expanded') ?? (tag === 'details' ? String(el.open) : null);
      if (expanded === 'true') out.push('expanded');
      else if (expanded === 'false') out.push('collapsed');
      if (el.getAttribute('aria-selected') === 'true' || (tag === 'option' && el.selected)) out.push('selected');
      if (el.getAttribute('aria-pressed') === 'true') out.push('pressed');
      if (el.required || el.getAttribute('aria-required') === 'true') out.push('required');
      if (el.readOnly && (tag === 'input' || tag === 'textarea')) out.push('readonly');
      if (el.ownerDocument.activeElement === el && el !== el.ownerDocument.body) out.push('focused');
      if (el.getAttribute('aria-invalid') === 'true') out.push('invalid');
      return out;
    };
    const styleOf = el => el.ownerDocument.defaultView.getComputedStyle(el);
    const hasBox = el => { const box = el.getBoundingClientRect(); return box.width > 0 && box.height > 0; };
    const isVisible = el => {
      if (!el.isConnected) return false;
      for (let node = el; node && node.nodeType === 1; node = node.parentElement || (node.getRootNode() && node.getRootNode().host)) {
        const style = styleOf(node);
        if (style.display === 'none') return false;
      }
      const style = styleOf(el);
      return style.visibility !== 'hidden' && style.visibility !== 'collapse' && hasBox(el);
    };

    // Same-origin frames and open shadow roots are part of the tree.
    const childrenOf = el => {
      const tag = tagOf(el);
      if (tag === 'iframe' || tag === 'frame') {
        let doc = null;
        try { doc = el.contentDocument; } catch (error) { doc = null; }
        return doc && doc.body ? [doc.body] : [];
      }
      if (el.shadowRoot) return Array.from(el.shadowRoot.childNodes);
      if (tag === 'slot') {
        const assigned = el.assignedNodes({ flatten: true });
        return assigned.length ? assigned : Array.from(el.childNodes);
      }
      return Array.from(el.childNodes);
    };
    const crossOrigin = el => {
      if (!['iframe', 'frame'].includes(tagOf(el))) return false;
      try { return !el.contentDocument; } catch (error) { return true; }
    };
    const clickable = (el, style) => {
      if (el.hasAttribute('onclick') || (el.hasAttribute('tabindex') && el.tabIndex >= 0)) return true;
      if (style.cursor !== 'pointer') return false;
      const parent = el.parentElement;
      return !parent || styleOf(parent).cursor !== 'pointer';
    };

    const snapshot = options => {
      const lines = [];
      const nodes = [];
      const frames = [];
      let truncated = false;
      const emit = (depth, line, node) => {
        if (lines.length >= LINE_LIMIT) { truncated = true; return; }
        lines.push((options.interactive ? '' : '  '.repeat(depth)) + line);
        if (node) nodes.push(node);
      };
      // Builds the tree first so compact can drop empty structure.
      const build = (el, insideNamed) => {
        if (el.nodeType === 3) {
          if (options.interactive || insideNamed) return [];
          const text = clean(el.data, 300);
          return text ? [{ text }] : [];
        }
        if (el.nodeType !== 1 && el.nodeType !== 11) return [];
        if (el.nodeType === 11) return childrenOf(el).flatMap(child => build(child, insideNamed));
        const tag = tagOf(el);
        if (SKIP.has(tag) || el.getAttribute('aria-hidden') === 'true' || el.hidden && tag !== 'details') return [];
        const style = styleOf(el);
        if (style.display === 'none') return [];
        const shown = style.visibility !== 'hidden' && style.visibility !== 'collapse';
        let role = shown ? roleOf(el) : null;
        if (!role && shown && clickable(el, style) && hasBox(el)) role = 'clickable';
        if (role === 'clickable' && insideNamed) role = null;
        const interactive = role !== null && INTERACTIVE.has(role);
        const keep = role !== null && (interactive ? hasBox(el) || tagOf(el) === 'option' : STRUCTURE.has(role));
        if (role === 'img' && keep && !nameOf(el, role)) return [];
        const children = childrenOf(el).flatMap(child => build(child, insideNamed || (keep && NAME_FROM_CONTENT.has(role))));
        if (!keep) return children;
        return [{ el, role, interactive, children }];
      };
      const render = (items, depth) => {
        for (const item of items) {
          if (lines.length >= LINE_LIMIT) { truncated = true; return; }
          if (item.text !== undefined) {
            if (options.depth === null || depth <= options.depth) emit(depth, 'text ' + quote(item.text));
            continue;
          }
          const { el, role, interactive } = item;
          const show = (!options.interactive || interactive) && (options.depth === null || depth <= options.depth);
          if (show) {
            const ref = refOf(el);
            const name = nameOf(el, role);
            const value = valueOf(el, role);
            const flags = states(el, role, options);
            let line = '@' + ref + ' [' + role + ']';
            if (name) line += ' ' + quote(name);
            if (value !== null && value !== '' && value !== name) line += ' value=' + quote(value);
            for (const flag of flags) line += ' [' + flag + ']';
            const node = { ref, role, name, depth };
            if (value !== null) node.value = value;
            if (flags.length) node.states = flags;
            if (role === 'link' && options.urls && el.href) {
              line += ' href=' + quote(String(el.href));
              node.href = String(el.href);
            }
            if (crossOrigin(el)) node.crossOrigin = true;
            emit(depth, line, node);
          }
          if (crossOrigin(el) && lines.length < LINE_LIMIT) {
            frames.push({ at: lines.length, line: show ? lines.length - 1 : -1, token: linkToken(el),
                          depth: show && !options.interactive ? depth + 1 : depth });
          }
          render(item.children, show && !options.interactive ? depth + 1 : depth);
        }
      };
      const prune = items => items.flatMap(item => {
        if (item.text !== undefined) return [item];
        item.children = prune(item.children);
        if (item.interactive || item.children.length || nameOf(item.el, item.role)) return [item];
        return [];
      });
      let roots;
      if (options.selector) {
        let matches;
        const id = refName(options.selector);
        if (id) matches = [find(options.selector)];
        else matches = queryAll(options.selector, false);
        roots = matches.filter(Boolean);
      } else {
        roots = document.body ? [document.body] : [];
      }
      for (const root of roots) {
        let tree = build(root, false);
        if (options.compact) tree = prune(tree);
        render(tree, 0);
      }
      return { lines, nodes, frames, truncated };
    };

    // Cross-origin frames: each gets a token the app learns the frame by
    // once the frame's listener hands it back.
    const frameTokens = new WeakMap();
    const tokenFrames = new Map();
    const linkToken = el => {
      let token = frameTokens.get(el);
      if (!token) {
        token = Math.random().toString(36).slice(2) + Date.now().toString(36);
        frameTokens.set(el, token);
        tokenFrames.set(token, new WeakRef(el));
      }
      return token;
    };
    const linkFrames = () => {
      const tokens = [];
      for (const scope of scopes()) {
        for (const el of scope.querySelectorAll('iframe, frame')) {
          if (!crossOrigin(el) || !isVisible(el)) continue;
          const token = linkToken(el);
          try { el.contentWindow.postMessage({ __tabAgentFrame: token }, '*'); } catch (error) { continue; }
          tokens.push(token);
        }
      }
      return tokens;
    };
    // Where a linked frame's content starts in this frame's viewport.
    const frameBox = token => {
      const el = tokenFrames.get(token)?.deref();
      if (!el || !el.isConnected) throw new Error('stale frame: the frame is gone from the page; run snapshot again');
      el.scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: 'instant' });
      const box = boxOf(el);
      const style = styleOf(el);
      return { x: box.x + parseFloat(style.borderLeftWidth) + parseFloat(style.paddingLeft),
               y: box.y + parseFloat(style.borderTopWidth) + parseFloat(style.paddingTop),
               width: box.width, height: box.height, viewport: window.innerWidth };
    };

    // The element's box in the top page's viewport, in CSS pixels.
    const boxOf = el => {
      const box = el.getBoundingClientRect();
      let x = box.left, y = box.top;
      for (let view = el.ownerDocument.defaultView; view && view !== window; view = view.parent) {
        const frame = view.frameElement;
        if (!frame) break;
        const outer = frame.getBoundingClientRect();
        const style = styleOf(frame);
        x += outer.left + parseFloat(style.borderLeftWidth) + parseFloat(style.paddingLeft);
        y += outer.top + parseFloat(style.borderTopWidth) + parseFloat(style.paddingTop);
      }
      return { x, y, width: box.width, height: box.height };
    };
    const describe = el => {
      let text = '<' + tagOf(el);
      if (el.id) text += '#' + el.id;
      const classes = typeof el.className === 'string' ? el.className.trim().split(/\s+/).filter(Boolean).slice(0, 2) : [];
      for (const name of classes) text += '.' + name;
      return text + '>';
    };
    // What a click at (x, y) of the top viewport lands on, inside frames and shadow roots.
    const hitAt = (x, y) => {
      let doc = document, hit = null;
      for (let guard = 0; guard < 32; guard++) {
        let found = doc.elementFromPoint(x, y);
        while (found && found.shadowRoot) {
          const inner = found.shadowRoot.elementFromPoint(x, y);
          if (!inner || inner === found) break;
          found = inner;
        }
        hit = found;
        if (!found || !['iframe', 'frame'].includes(tagOf(found))) return hit;
        let inner = null;
        try { inner = found.contentDocument; } catch (error) { inner = null; }
        if (!inner) return hit;
        const outer = found.getBoundingClientRect();
        const style = styleOf(found);
        x -= outer.left + parseFloat(style.borderLeftWidth) + parseFloat(style.paddingLeft);
        y -= outer.top + parseFloat(style.borderTopWidth) + parseFloat(style.paddingTop);
        doc = inner;
      }
      return hit;
    };
    const composedContains = (el, node) => {
      for (let current = node; current; current = current.parentNode || current.host) {
        if (current === el) return true;
      }
      return false;
    };
    const fail = (code, detail) => { throw new Error(code + (detail ? ' ' + detail : '')); };

    // Scrolls the element into view and checks a pointer can reach it.
    // Returns its center in the top viewport and the viewport's width.
    const prepare = (target, action) => {
      const el = find(target);
      if (!el) return null;
      if (!el.isConnected) fail('stale');
      el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
      if (!isVisible(el)) fail('not_visible', describe(el));
      if (action !== 'hover' && action !== 'focus' && isDisabled(el)) fail('disabled', describe(el));
      if ((action === 'fill' || action === 'type') && !isEditable(el)) fail('not_editable', describe(el));
      const box = boxOf(el);
      const x = box.x + box.width / 2, y = box.y + box.height / 2;
      if (action !== 'type' && action !== 'fill' && action !== 'focus') {
        const hit = hitAt(x, y);
        const label = hit && tagOf(hit) === 'label' && hit.control === el;
        if (hit && !composedContains(el, hit) && !label && !composedContains(hit, el)) fail('covered by', describe(hit));
      }
      return { x, y, width: box.width, height: box.height, viewport: window.innerWidth };
    };

    // Focuses a field and puts the caret at the end, or selects all of it.
    const focusField = (el, selectAll) => {
      el.focus();
      const tag = tagOf(el);
      if (tag === 'input' || tag === 'textarea') {
        try {
          const length = el.value.length;
          if (selectAll) el.setSelectionRange(0, length);
          else el.setSelectionRange(length, length);
        } catch (error) { if (selectAll && el.select) el.select(); }
      } else if (el.isContentEditable) {
        const selection = el.ownerDocument.getSelection();
        const range = el.ownerDocument.createRange();
        range.selectNodeContents(el);
        if (!selectAll) range.collapse(false);
        selection.removeAllRanges();
        selection.addRange(range);
      }
      return { value: fieldValue(el), start: el.selectionStart ?? null, end: el.selectionEnd ?? null };
    };
    const fieldValue = el => tagOf(el) === 'input' || tagOf(el) === 'textarea' || tagOf(el) === 'select' ? el.value : el.textContent;
    const setValue = (el, value) => {
      const tag = tagOf(el);
      const prototype = tag === 'textarea' ? HTMLTextAreaElement.prototype
        : tag === 'select' ? HTMLSelectElement.prototype
        : tag === 'input' ? HTMLInputElement.prototype : null;
      const setter = prototype && Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
      if (setter) setter.call(el, value);
      else if (el.isContentEditable) el.textContent = value;
      else el.value = value;
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    };
    // Replaces the selection as typing would, with trusted input events;
    // falls back to setting the value where editing commands don't apply.
    const insertText = (el, text, replaceAll) => {
      // A single-line field drops line breaks, as setting its value would.
      if (tagOf(el) === 'input') text = text.replace(/[\r\n]+/g, '');
      const before = fieldValue(el);
      focusField(el, replaceAll);
      const doc = el.ownerDocument;
      let done = false;
      try {
        done = text === '' ? doc.execCommand('delete', false) : doc.execCommand('insertText', false, text);
      } catch (error) { done = false; }
      const expected = replaceAll ? text : before + text;
      const after = fieldValue(el);
      if (!done || (replaceAll && after !== text && tagOf(el) !== 'input' && !el.isContentEditable)) {
        setValue(el, expected);
      } else if (after !== expected && straightQuotes(after) === straightQuotes(expected)) {
        // macOS smart quotes curl typed quotes; agents mean the exact text.
        setValue(el, expected);
      }
      return fieldValue(el);
    };
    const straightQuotes = value => value.replace(/[\u2018\u2019\u201A\u201B]/g, "'").replace(/[\u201C\u201D\u201E\u201F]/g, '"');
    const pressKey = (el, key) => {
      for (const type of ['keydown', 'keypress', 'keyup']) {
        el.dispatchEvent(new KeyboardEvent(type, { key, bubbles: true, cancelable: true, composed: true }));
      }
    };
    const submit = el => {
      const form = el.form || el.closest('form');
      if (!form) pressKey(el, 'Enter');
      else if (form.requestSubmit) form.requestSubmit();
      else form.submit();
    };
    const scriptClick = (el, count = 1, button = 0) => {
      const view = el.ownerDocument.defaultView;
      const box = el.getBoundingClientRect();
      const init = { bubbles: true, cancelable: true, composed: true, view, clientX: box.left + box.width / 2,
                     clientY: box.top + box.height / 2, button, buttons: button === 2 ? 2 : 1 };
      for (let detail = 1; detail <= count; detail++) {
        el.dispatchEvent(new view.PointerEvent('pointerdown', { ...init, detail, pointerType: 'mouse', isPrimary: true }));
        el.dispatchEvent(new view.MouseEvent('mousedown', { ...init, detail }));
        if (detail === 1 && el.focus) el.focus();
        el.dispatchEvent(new view.PointerEvent('pointerup', { ...init, detail, pointerType: 'mouse', isPrimary: true }));
        el.dispatchEvent(new view.MouseEvent('mouseup', { ...init, detail }));
        if (button === 2) el.dispatchEvent(new view.MouseEvent('contextmenu', { ...init, detail }));
        else if (detail === 1) el.click();
        else el.dispatchEvent(new view.MouseEvent('click', { ...init, detail }));
      }
      if (count === 2 && button === 0) el.dispatchEvent(new view.MouseEvent('dblclick', { ...init, detail: 2 }));
    };
    const scriptHover = el => {
      const view = el.ownerDocument.defaultView;
      for (const type of ['pointerover', 'pointerenter', 'mouseover', 'mouseenter', 'pointermove', 'mousemove']) {
        const Kind = type.startsWith('pointer') ? view.PointerEvent : view.MouseEvent;
        el.dispatchEvent(new Kind(type, { bubbles: !type.endsWith('enter'), cancelable: true, composed: true, view }));
      }
    };

    // The file field an element stands for: itself, its label's control, or
    // the one file field inside it.
    const fileInput = el => {
      const isFile = node => node && node.localName === 'input' && inputType(node) === 'file';
      if (isFile(el)) return el;
      if (tagOf(el) === 'label' && isFile(el.control)) return el.control;
      const inner = el.querySelectorAll ? Array.from(el.querySelectorAll('input[type=file]')) : [];
      return inner.length === 1 ? inner[0] : null;
    };
    // Gives a file field `files` ({name, type, data (base64), lastModified})
    // as if the user had chosen them.
    const setFiles = (el, files) => {
      const input = fileInput(el);
      if (!input) fail('not_file_input', describe(el));
      if (input.disabled) fail('disabled', describe(input));
      if (files.length > 1 && !input.multiple) fail('single_file', describe(input) + ' takes one file');
      const transfer = new DataTransfer();
      for (const file of files) {
        const binary = atob(file.data);
        const bytes = new Uint8Array(binary.length);
        for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
        transfer.items.add(new File([bytes], file.name, { type: file.type, lastModified: file.lastModified }));
      }
      input.files = transfer.files;
      input.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
      input.dispatchEvent(new Event('change', { bubbles: true }));
      return Array.from(input.files).map(file => file.name);
    };
    // Scrolls the page, or an element that scrolls, by (dx, dy) CSS pixels.
    const scroll = (target, dx, dy) => {
      if (target) {
        const el = find(target);
        if (!el) return null;
        el.scrollBy({ left: dx, top: dy, behavior: 'instant' });
        return { x: el.scrollLeft, y: el.scrollTop };
      }
      window.scrollBy({ left: dx, top: dy, behavior: 'instant' });
      return { x: window.scrollX, y: window.scrollY };
    };

    // Resolves once the DOM has had no changes for `quiet` ms, or after `limit` ms.
    const quiet = (quietMs, limit) => new Promise(resolve => {
      let timer = null;
      const started = Date.now();
      const observer = new MutationObserver(() => arm());
      const finish = () => { observer.disconnect(); clearTimeout(timer); clearTimeout(cap); resolve(Date.now() - started); };
      const arm = () => { clearTimeout(timer); timer = setTimeout(() => requestAnimationFrame(() => finish()), quietMs); };
      const cap = setTimeout(finish, limit);
      observer.observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
      arm();
    });

    // Numbered labels over interactive elements, for annotated screenshots.
    const OVERLAY = '__tab-agent-annotations';
    const annotate = () => {
      clearAnnotations();
      const shot = snapshot({ interactive: true, compact: false, depth: null, selector: null, urls: false });
      const layer = document.createElement('div');
      layer.id = OVERLAY;
      layer.setAttribute('style', 'position:absolute;left:0;top:0;width:0;height:0;z-index:2147483647;pointer-events:none;');
      const labels = [];
      for (const node of shot.nodes) {
        const el = refs.get(node.ref)?.deref();
        if (!el) continue;
        const box = boxOf(el);
        if (box.width <= 0 || box.height <= 0) continue;
        if (box.y + box.height < 0 || box.y > window.innerHeight || box.x + box.width < 0 || box.x > window.innerWidth) continue;
        const left = box.x + window.scrollX, top = box.y + window.scrollY;
        const frame = document.createElement('div');
        frame.setAttribute('style', `position:absolute;left:${left}px;top:${top}px;width:${box.width}px;height:${box.height}px;outline:2px solid #e5484d;box-sizing:border-box;`);
        const tag = document.createElement('div');
        tag.textContent = node.ref.slice(1);
        tag.setAttribute('style', `position:absolute;left:${left}px;top:${Math.max(top - 14, 0)}px;font:bold 11px/14px -apple-system,sans-serif;color:#fff;background:#e5484d;padding:0 3px;border-radius:3px;`);
        layer.append(frame, tag);
        labels.push(node.ref);
      }
      document.documentElement.appendChild(layer);
      return labels;
    };
    const clearAnnotations = () => { document.getElementById(OVERLAY)?.remove(); };

    const legacyFind = (kind, value) => {
      const needle = value.toLowerCase();
      const includes = text => (text || '').toLowerCase().includes(needle);
      const matches = {
        role: el => roleOf(el) === value,
        testid: el => el.getAttribute('data-testid') === value,
        label: el => includes(el.getAttribute('aria-label')) || Array.from(el.labels || []).some(item => includes(item.innerText)),
        placeholder: el => includes(el.getAttribute('placeholder')),
        text: el => includes(el.innerText),
      }[kind];
      if (!matches) throw new Error('unknown find kind ' + kind + '; use role, text, label, placeholder or testid');
      const found = scopes().flatMap(scope => Array.from(scope.querySelectorAll(scope.body ? 'body *' : '*'))).filter(matches);
      return found
        .filter(el => !found.some(other => other !== el && el.contains(other)))
        .slice(0, 20)
        .map(el => ({ ref: '@' + refOf(el), tag: tagOf(el), text: legacyLabel(el), role: roleOf(el), id: el.id || null, testid: el.getAttribute('data-testid'), selector: selectorOf(el) }));
    };
    const legacyLabel = el => (el.innerText || el.value || el.getAttribute('aria-label') || el.getAttribute('placeholder') || '').trim().slice(0, 120);
    const selectorOf = el => {
      if (el.id && document.querySelectorAll('#' + CSS.escape(el.id)).length === 1) return '#' + CSS.escape(el.id);
      const testid = el.getAttribute('data-testid');
      if (testid) {
        const selector = '[data-testid="' + CSS.escape(testid) + '"]';
        if (document.querySelectorAll(selector).length === 1) return selector;
      }
      const parts = [];
      for (let node = el; node && node.nodeType === 1 && node !== document.documentElement; node = node.parentElement) {
        const tag = node.tagName.toLowerCase();
        const siblings = node.parentElement ? Array.from(node.parentElement.children).filter(child => child.tagName === node.tagName) : [];
        parts.unshift(siblings.length > 1 ? tag + ':nth-of-type(' + (siblings.indexOf(node) + 1) + ')' : tag);
      }
      return parts.join(' > ');
    };
    // The elements the first snapshot format listed, now with refs too.
    const legacySnapshot = selector => {
      const root = selector ? find(selector) : document.body;
      if (!root) return [];
      const interactive = 'a, button, input, textarea, select, summary, [role=button], [role=link], [role=tab], [role=checkbox], [role=menuitem], [onclick], [contenteditable=true]';
      return Array.from(root.querySelectorAll(interactive))
        .filter(el => isVisible(el))
        .slice(0, 200)
        .map(el => ({ ref: '@' + refOf(el), tag: tagOf(el), role: roleOf(el) || el.type || null, name: legacyLabel(el), id: el.id || null, testid: el.getAttribute('data-testid'), selector: selectorOf(el), visible: true }));
    };

    Object.defineProperty(globalThis, '__tabAgent', { value: Object.freeze({
      next: () => counter, find, snapshot, prepare, boxOf, isVisible, isDisabled, isEditable, focusField, fieldValue,
      setValue, insertText, pressKey, submit, scriptClick, scriptHover, quiet, annotate, clearAnnotations,
      legacyFind, legacySnapshot, refOf, describe, queryAll, linkFrames, frameBox, fileInput, setFiles, scroll,
    }) });
    })();
    """#

    /// Captures console messages, uncaught errors and fetch/XHR requests and
    /// posts them to the app. Runs in the page's world, at document start.
    static let logCapture = #"""
    (() => {
    if (window.__tabAgentLogs) return;
    Object.defineProperty(window, '__tabAgentLogs', { value: true });
    const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tabAgentLog;
    if (!handler) return;
    const post = handler.postMessage.bind(handler);
    const send = message => { try { post(message); } catch (error) {} };
    const format = value => {
      try {
        if (typeof value === 'string') return value;
        if (value instanceof Error) return value.stack ? value.message + '\n' + value.stack : String(value);
        if (value instanceof Element) return '<' + value.localName + (value.id ? '#' + value.id : '') + '>';
        const json = JSON.stringify(value);
        return json === undefined ? String(value) : json;
      } catch (error) { return String(value); }
    };
    for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
      const original = console[level];
      if (typeof original !== 'function') continue;
      console[level] = function(...args) {
        send({ kind: 'console', level, text: args.map(format).join(' ').slice(0, 4000), url: location.href });
        return original.apply(this, args);
      };
    }
    addEventListener('error', event => {
      if (!(event instanceof ErrorEvent)) return;
      send({ kind: 'error', text: String(event.message).slice(0, 4000), source: event.filename || '', line: event.lineno || 0,
             column: event.colno || 0, stack: String(event.error && event.error.stack || '').slice(0, 4000) });
    }, true);
    addEventListener('unhandledrejection', event => {
      const reason = event.reason;
      send({ kind: 'error', text: ('Unhandled rejection: ' + format(reason && reason.message || reason)).slice(0, 4000),
             source: '', line: 0, column: 0, stack: String(reason && reason.stack || '').slice(0, 4000) });
    });
    // A window the page opens becomes a browser pane; actions wait for the ones they cause.
    const originalOpen = window.open;
    if (typeof originalOpen === 'function') {
      window.open = function() {
        send({ kind: 'open' });
        return originalOpen.apply(this, arguments);
      };
    }
    const prefix = Math.random().toString(36).slice(2, 8) + '-';
    let sequence = 0;
    const BODY_LIMIT = 32768;
    const absolute = url => { try { return new URL(String(url), location.href).href; } catch (error) { return String(url); } };
    const cut = text => text.length > BODY_LIMIT ? text.slice(0, BODY_LIMIT) + '… (' + text.length + ' characters)' : text;
    const bodyText = body => {
      if (body === undefined || body === null) return undefined;
      if (typeof body === 'string') return cut(body);
      if (body instanceof URLSearchParams) return cut(body.toString());
      if (typeof FormData !== 'undefined' && body instanceof FormData) {
        return cut(Array.from(body.entries()).map(([key, value]) => key + '=' + (typeof value === 'string' ? value : '<file ' + value.name + '>')).join('&'));
      }
      return '<' + (body.constructor && body.constructor.name || typeof body) + '>';
    };
    const headerObject = headers => {
      const out = {};
      try {
        if (!headers) return out;
        if (typeof headers.forEach === 'function' && !Array.isArray(headers)) headers.forEach((value, key) => { out[String(key).toLowerCase()] = String(value); });
        else if (Array.isArray(headers)) for (const [key, value] of headers) out[String(key).toLowerCase()] = String(value);
        else for (const key of Object.keys(headers)) out[key.toLowerCase()] = String(headers[key]);
      } catch (error) {}
      return out;
    };
    // Text bodies only, and not huge ones.
    const readable = type => /^(text\/|application\/(json|xml|javascript|x-www-form-urlencoded|[a-z.+-]*\+(json|xml)))/i.test(type || '');
    const originalFetch = window.fetch;
    if (typeof originalFetch === 'function') {
      window.fetch = function(input, init) {
        const id = prefix + (++sequence);
        const method = String(init && init.method || input && input.method || 'GET').toUpperCase();
        const url = absolute(input && input.url || input);
        const started = performance.now();
        const headers = Object.assign(headerObject(input && input.headers), headerObject(init && init.headers));
        send({ kind: 'request', phase: 'start', id, method, url, type: 'fetch', headers, body: bodyText(init && init.body) });
        let promise;
        try { promise = originalFetch.apply(this, arguments); }
        catch (error) { send({ kind: 'request', phase: 'end', id, error: String(error), ms: 0 }); throw error; }
        return promise.then(response => {
          const contentType = response.headers.get('content-type') || '';
          send({ kind: 'request', phase: 'end', id, status: response.status, ms: Math.round(performance.now() - started),
                 headers: headerObject(response.headers), contentType });
          const length = Number(response.headers.get('content-length') || 0);
          if (readable(contentType) && length <= 4 * BODY_LIMIT) {
            try { response.clone().text().then(text => send({ kind: 'request', phase: 'body', id, body: cut(text) }), () => {}); }
            catch (error) {}
          }
          return response;
        }, error => {
          send({ kind: 'request', phase: 'end', id, error: String(error && error.message || error), ms: Math.round(performance.now() - started) });
          throw error;
        });
      };
    }
    const XHR = window.XMLHttpRequest;
    if (XHR) {
      const open = XHR.prototype.open, sendRequest = XHR.prototype.send, setHeader = XHR.prototype.setRequestHeader;
      XHR.prototype.open = function(method, url) {
        this.__tabRequest = { method: String(method || 'GET').toUpperCase(), url: absolute(url), headers: {} };
        return open.apply(this, arguments);
      };
      XHR.prototype.setRequestHeader = function(name, value) {
        if (this.__tabRequest) this.__tabRequest.headers[String(name).toLowerCase()] = String(value);
        return setHeader.apply(this, arguments);
      };
      XHR.prototype.send = function(body) {
        const request = this.__tabRequest;
        if (request) {
          const id = prefix + (++sequence);
          const started = performance.now();
          send({ kind: 'request', phase: 'start', id, method: request.method, url: request.url, type: 'xhr',
                 headers: request.headers, body: bodyText(body) });
          this.addEventListener('loadend', () => {
            const ms = Math.round(performance.now() - started);
            if (!this.status) return send({ kind: 'request', phase: 'end', id, error: 'failed', ms });
            const headers = {};
            for (const line of String(this.getAllResponseHeaders() || '').trim().split(/[\r\n]+/)) {
              const index = line.indexOf(':');
              if (index > 0) headers[line.slice(0, index).trim().toLowerCase()] = line.slice(index + 1).trim();
            }
            const contentType = headers['content-type'] || '';
            send({ kind: 'request', phase: 'end', id, status: this.status, ms, headers, contentType });
            try {
              let text;
              if (this.responseType === '' || this.responseType === 'text') text = this.responseText;
              else if (this.responseType === 'json') text = JSON.stringify(this.response);
              if (typeof text === 'string' && (readable(contentType) || this.responseType === 'json')) {
                send({ kind: 'request', phase: 'body', id, body: cut(text) });
              }
            } catch (error) {}
          });
        }
        return sendRequest.apply(this, arguments);
      };
    }
    })();
    """#
}
