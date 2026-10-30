import Foundation
import TabClient

/// The page side of browser automation, ported from Codesh's
/// `automation.rs`: each command becomes the body of an async JavaScript
/// function that runs in the page, and what it returns is the command's
/// result.
public enum BrowserScripts {
    /// How often waits check their condition.
    public static let pollInterval: TimeInterval = 0.1
    public static let elementHTMLLimit = 500
    public static let elementTextLimit = 1_000_000
    public static let cancelElementPicker = "window.__tabDomPicker?.cancel(); return null;"

    /// An automation failure, shown to the `tab browser` user as is.
    public struct Failure: Error, Equatable, CustomStringConvertible, LocalizedError {
        public var message: String
        public init(_ message: String) { self.message = message }
        public var description: String { message }
        public var errorDescription: String? { message }
    }

    // MARK: Arguments

    public static func string(_ args: JSONValue, _ key: String) throws -> String {
        guard let value = args[key]?.string else { throw Failure("missing argument '\(key)'") }
        return value
    }

    /// A non-empty string argument.
    public static func optionalString(_ args: JSONValue, _ key: String) -> String? {
        guard let value = args[key]?.string, !value.isEmpty else { return nil }
        return value
    }

    public static func flag(_ args: JSONValue, _ key: String) -> Bool {
        if case .bool(let value) = args[key] { return value }
        return false
    }

    /// The `timeoutMs` argument, within what a command may wait.
    public static func timeout(_ args: JSONValue, default fallback: TimeInterval) -> TimeInterval {
        guard case .int(let value) = args["timeoutMs"], value >= 0 else { return fallback }
        return min(Double(value) / 1000, BrowserCommand.maxWait)
    }

    // MARK: Scripts

    /// The script for a command that runs in the page, or `nil` when the app
    /// carries out `command` itself.
    public static func script(_ command: BrowserCommand, args: JSONValue) throws -> String? {
        func element(_ body: String) throws -> String {
            "\(helpers)const el = document.querySelector(\(literal(try string(args, "selector"))));\nif (!el) return false;\n\(body)\nreturn true;"
        }
        func value(_ body: String) throws -> String {
            "const el = document.querySelector(\(literal(try string(args, "selector"))));\nreturn el ? \(body) : null;"
        }
        switch command {
        case .evaluate:
            return functionBody(try string(args, "script"))
        case .read:
            return "return { title: document.title, url: location.href, text: (document.body ? document.body.innerText : '').slice(0, 1000000) };"
        case .click:
            return try element("el.click();")
        case .fill:
            return try element("el.focus();\nsetValue(el, \(literal(try string(args, "text"))));")
        case .type:
            return try element("el.focus();\nsetValue(el, \(literal(try string(args, "text"))));\nif (\(flag(args, "submit"))) submit(el);")
        case .select:
            return try element("setValue(el, \(literal(try string(args, "value"))));")
        case .hover:
            return try element("for (const type of ['mouseover', 'mouseenter', 'mousemove']) el.dispatchEvent(new MouseEvent(type, { bubbles: type !== 'mouseenter', cancelable: true, view: window }));")
        case .scrollIntoView:
            return try element("el.scrollIntoView({ block: 'center', inline: 'center' });")
        case .setChecked:
            return try element("if (el.checked !== \(flag(args, "checked"))) el.click();")
        case .press:
            let target = optionalString(args, "selector").map { "document.querySelector(\(literal($0)))" }
                ?? "document.activeElement || document.body"
            return "\(helpers)const el = \(target);\nif (!el) return false;\npressKey(el, \(literal(try string(args, "key"))));\nreturn true;"
        case .is:
            let check: String
            switch try string(args, "property") {
            case "checked": check = "return Boolean(el.checked);"
            case "enabled": check = "return !el.disabled;"
            case "disabled": check = "return Boolean(el.disabled);"
            case "hidden": check = "return !visible(el);"
            default: check = "return visible(el);"
            }
            return "\(helpers)const el = document.querySelector(\(literal(try string(args, "selector"))));\nif (!el) return false;\n\(check)"
        case .getText:
            return try value("el.innerText")
        case .getValue:
            return try value("(el.value ?? null)")
        case .getAttribute:
            return try value("el.getAttribute(\(literal(try string(args, "attribute"))))")
        case .getHTML:
            if optionalString(args, "selector") != nil { return try value("el.outerHTML.slice(0, 5000000)") }
            return "return document.documentElement.outerHTML.slice(0, 5000000);"
        case .getCount:
            return "return document.querySelectorAll(\(literal(try string(args, "selector")))).length;"
        case .find:
            return "\(helpers)return find(\(literal(optionalString(args, "kind") ?? "text")), \(literal(try string(args, "value"))));"
        case .snapshot:
            return "\(helpers)return snapshot(\(optionalString(args, "selector").map(literal) ?? "null"));"
        case .storageGet:
            return "return \(try storage(args)).getItem(\(literal(try string(args, "key"))));"
        case .storageSet:
            return "\(try storage(args)).setItem(\(literal(try string(args, "key"))), \(literal(try string(args, "value"))));\nreturn null;"
        case .storageClear:
            return "\(try storage(args)).clear();\nreturn null;"
        case .open, .list, .navigate, .close, .reload, .back, .forward, .screenshot, .wait, .waitFor,
             .waitForNavigation, .cookiesGet, .cookiesSet, .cookiesDelete, .cookiesClear:
            return nil
        }
    }

    /// A check for `wait` and `waitFor` that returns whether the condition
    /// holds. Errors count as not yet.
    public static func condition(_ command: BrowserCommand, args: JSONValue) throws -> String {
        let check: String
        switch command {
        case .waitFor:
            check = "return document.querySelector(\(literal(try string(args, "selector")))) !== null;"
        case .wait:
            if let function = optionalString(args, "function") {
                check = "return Boolean(await (async () => { \(functionBody(function)) })());"
            } else if let selector = optionalString(args, "selector") {
                check = "return document.querySelector(\(literal(selector))) !== null;"
            } else if let text = optionalString(args, "text") {
                check = "return (document.body ? document.body.innerText : '').includes(\(literal(text)));"
            } else if let fragment = optionalString(args, "urlContains") {
                check = "return location.href.includes(\(literal(fragment)));"
            } else {
                check = "return true;"
            }
        default:
            throw Failure("unknown command browser.\(command.rawValue)")
        }
        return "try {\n\(check)\n} catch (error) {\nreturn false;\n}"
    }

    /// A script given on the command line: a single expression whose value is
    /// the result, or a statement list that returns. Only a syntax error picks
    /// the statement form, so an expression never runs twice.
    static func functionBody(_ script: String) -> String {
        let statements = script.trimmingCharacters(in: .whitespacesAndNewlines)
        var expression = statements
        while expression.hasSuffix(";") { expression.removeLast() }
        let wrapped = "return (\n\(expression)\n);"
        return """
        const AsyncFunction = Object.getPrototypeOf(async function() {}).constructor;
        let run;
        try { run = new AsyncFunction(\(literal(wrapped))); }
        catch (error) { if (!(error instanceof SyntaxError)) throw error; run = new AsyncFunction(\(literal(statements))); }
        return await run.call(this);
        """
    }

    private static func storage(_ args: JSONValue) throws -> String {
        switch optionalString(args, "kind") ?? "local" {
        case "local": return "window.localStorage"
        case "session": return "window.sessionStorage"
        case let other: throw Failure("unknown storage '\(other)'; use local or session")
        }
    }

    /// `value` as a JavaScript string literal.
    public static func literal(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{2028}": result += "\\u2028"
            case "\u{2029}": result += "\\u2029"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    /// Wraps a function body so its result comes back as JSON text, which the
    /// app decodes; `undefined` becomes `null`.
    static func jsonWrapped(_ body: String) -> String {
        "const __tabResult = await (async function() {\n\(body)\n}).call(this);\nreturn JSON.stringify(__tabResult === undefined ? null : __tabResult);"
    }

    /// The element picker: highlights what the pointer is over and resolves
    /// with the clicked element's address, selector, HTML and text, or `null`
    /// on Escape.
    public static func elementPicker(accent: String) -> String {
        "\(helpers)\nconst pickerAccent = \(literal(accent));\nconst pickerLimits = { html: \(elementHTMLLimit), text: \(elementTextLimit) };\n\(elementPickerBody)"
    }

    /// What the element picker copies: the page, the element's HTML (cut to
    /// save tokens) and its text.
    public static func elementClipboardText(_ selection: JSONValue) -> String? {
        guard let url = selection["url"]?.string, let htmlSource = selection["html"]?.string,
              let text = selection["text"]?.string
        else { return nil }
        let htmlTruncated = selection["htmlTruncated"] == .bool(true)
        let textTruncated = selection["textTruncated"] == .bool(true)
        let html = String(htmlSource.prefix(elementHTMLLimit))
        var copied = "Page: \(url)\n\nHTML:\n\(html)"
        if html.count < htmlSource.count || htmlTruncated {
            copied += "\n… [remaining HTML omitted to save tokens]"
        }
        let shownText = String(text.prefix(elementTextLimit))
        if !shownText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copied += "\n\nText:\n" + shownText
            if textTruncated || shownText.count < text.count {
                copied += "\n\n[Text truncated by Tab at its 1,000,000-character safety limit]"
            }
        }
        return copied
    }

    static let helpers = #"""
    const setValue = (el, value) => {
      const prototype = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype
        : el instanceof HTMLSelectElement ? HTMLSelectElement.prototype
        : el instanceof HTMLInputElement ? HTMLInputElement.prototype : null;
      const setter = prototype && Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
      if (setter) setter.call(el, value);
      else if (el.isContentEditable) el.textContent = value;
      else el.value = value;
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    };
    const pressKey = (el, key) => {
      for (const type of ['keydown', 'keypress', 'keyup']) {
        el.dispatchEvent(new KeyboardEvent(type, { key, bubbles: true, cancelable: true }));
      }
    };
    const submit = el => {
      const form = el.form || el.closest('form');
      if (!form) pressKey(el, 'Enter');
      else if (form.requestSubmit) form.requestSubmit();
      else form.submit();
    };
    const visible = el => {
      const box = el.getBoundingClientRect();
      const style = getComputedStyle(el);
      return box.width > 0 && box.height > 0 && style.visibility !== 'hidden' && style.display !== 'none';
    };
    const label = el => (el.innerText || el.value || el.getAttribute('aria-label') || el.getAttribute('placeholder') || '').trim().slice(0, 120);
    const roleOf = el => {
      const explicit = el.getAttribute('role');
      if (explicit) return explicit;
      const tag = el.tagName.toLowerCase();
      if (tag === 'a' && el.hasAttribute('href')) return 'link';
      if (tag === 'button' || tag === 'summary') return 'button';
      if (tag === 'select') return 'combobox';
      if (tag === 'textarea') return 'textbox';
      if (/^h[1-6]$/.test(tag)) return 'heading';
      if (tag === 'img') return 'img';
      if (tag === 'input') {
        const type = (el.getAttribute('type') || 'text').toLowerCase();
        if (['button', 'submit', 'reset', 'image'].includes(type)) return 'button';
        if (['checkbox', 'radio', 'range'].includes(type)) return type === 'range' ? 'slider' : type;
        return type === 'search' ? 'searchbox' : 'textbox';
      }
      return null;
    };
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
    const find = (kind, value) => {
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
      const found = Array.from(document.body ? document.body.querySelectorAll('*') : []).filter(matches);
      return found
        .filter(el => !found.some(other => other !== el && el.contains(other)))
        .slice(0, 20)
        .map(el => ({ tag: el.tagName.toLowerCase(), text: label(el), role: roleOf(el), id: el.id || null, testid: el.getAttribute('data-testid'), selector: selectorOf(el) }));
    };
    const snapshot = selector => {
      const root = selector ? document.querySelector(selector) : document.body;
      if (!root) return [];
      const interactive = 'a, button, input, textarea, select, summary, [role=button], [role=link], [role=tab], [role=checkbox], [role=menuitem], [onclick], [contenteditable=true]';
      return Array.from(root.querySelectorAll(interactive))
        .filter(visible)
        .slice(0, 200)
        .map(el => ({ tag: el.tagName.toLowerCase(), role: roleOf(el) || el.type || null, name: label(el), id: el.id || null, testid: el.getAttribute('data-testid'), selector: selectorOf(el), visible: true }));
    };

    """#

    private static let elementPickerBody = #"""
    return await new Promise((resolve, reject) => {
      const key = '__tabDomPicker';
      window[key]?.cancel();
      let highlighted = null;
      const restore = () => {
        const previous = highlighted;
        highlighted = null;
        if (!previous) return;
        const { element, properties, outline, outlinePriority, hadStyle } = previous;
        const style = element.style;
        const owned = property => style.getPropertyValue(property.name) === property.applied
          && style.getPropertyPriority(property.name) === 'important';
        if (outline) {
          const changes = properties.slice(0, 3)
            .filter(property => property.applied !== undefined && !owned(property))
            .map(property => ({
              name: property.name, value: style.getPropertyValue(property.name),
              priority: style.getPropertyPriority(property.name),
            }));
          style.setProperty('outline', outline, outlinePriority);
          for (const property of changes) {
            if (property.value) style.setProperty(property.name, property.value, property.priority);
            else style.removeProperty(property.name);
          }
        }
        for (const property of properties) {
          if (outline && property.name.startsWith('outline-') && property.name !== 'outline-offset') continue;
          if (!owned(property)) continue;
          if (property.value) style.setProperty(property.name, property.value, property.priority);
          else style.removeProperty(property.name);
        }
        if (!hadStyle && !style.cssText && element.hasAttribute('style')) element.removeAttribute('style');
      };
      const finish = (selection, error) => {
        try {
          for (const [type, handler] of listeners) window.removeEventListener(type, handler, true);
          restore();
          if (selection === undefined) reject(error);
          else resolve(selection);
        } catch (error) {
          reject(error);
        } finally {
          if (window[key] === picker) delete window[key];
        }
      };
      const guarded = handler => event => {
        try { handler(event); }
        catch (error) { finish(undefined, error); }
      };
      const target = event => event.composedPath().find(node => node instanceof Element);
      const excerpt = (value, limit) => {
        let end = 0;
        let count = 0;
        for (const character of value) {
          if (count === limit) break;
          end += character.length;
          count++;
        }
        return { value: value.slice(0, end), truncated: end < value.length };
      };
      const moved = guarded(event => {
        event.stopImmediatePropagation();
        const element = target(event);
        if (!element || element === highlighted?.element) return;
        restore();
        const style = element.style;
        const values = [
          ['outline-color', pickerAccent], ['outline-style', 'solid'], ['outline-width', '2px'],
          ['outline-offset', '2px'], ['cursor', 'pointer'],
        ];
        const properties = values.map(([name]) => ({
          name, value: style.getPropertyValue(name), priority: style.getPropertyPriority(name),
        }));
        highlighted = {
          element, properties, outline: style.getPropertyValue('outline'),
          outlinePriority: style.getPropertyPriority('outline'), hadStyle: element.hasAttribute('style'),
        };
        for (let index = 0; index < values.length; index++) {
          const [name, value] = values[index];
          style.setProperty(name, value, 'important');
          properties[index].applied = style.getPropertyValue(name);
        }
      });
      const pressed = guarded(event => {
        event.preventDefault();
        event.stopImmediatePropagation();
      });
      const clicked = guarded(event => {
        const element = target(event);
        if (!element) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        restore();
        const bounds = element.getBoundingClientRect();
        const html = excerpt(element.outerHTML, pickerLimits.html);
        const text = excerpt(String(element.innerText ?? element.textContent ?? ''), pickerLimits.text);
        finish({
          url: window.location.href,
          selector: selectorOf(element),
          bounds: { x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height },
          html: html.value, text: text.value,
          htmlTruncated: html.truncated, textTruncated: text.truncated,
        });
      });
      const keyed = guarded(event => {
        if (event.key === 'Escape') {
          event.preventDefault();
          event.stopImmediatePropagation();
          finish(null);
        }
      });
      const listeners = [
        ['pointermove', moved], ['pointerdown', pressed], ['pointerup', pressed],
        ['mousedown', pressed], ['mouseup', pressed], ['click', clicked], ['keydown', keyed],
      ];
      const picker = { cancel: () => finish(null) };
      window[key] = picker;
      try {
        for (const [type, handler] of listeners) window.addEventListener(type, handler, true);
      } catch (error) {
        finish(undefined, error);
      }
    });
    """#
}
