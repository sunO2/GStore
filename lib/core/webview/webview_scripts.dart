/// JavaScript injected into the headless page.
///
/// Keep these strings dependency-free and conservative: they run on whatever
/// Chromium version the device's Android System WebView provides.
library;

import 'dart:convert';

const String webViewFetchHookScript = r'''
(function () {
  if (window.__gstoreFetchHooked) return;
  window.__gstoreFetchHooked = true;

  var HANDLER = 'gstoreWebviewRequest';
  var MAX_BODY = 65536;
  var queue = [];

  function clip(text) {
    if (text === undefined || text === null) return null;
    text = String(text);
    return text.length <= MAX_BODY ? text : text.substring(0, MAX_BODY) + '…<截断>';
  }

  function headersToObject(headers) {
    var out = {};
    if (!headers) return out;
    try {
      if (typeof headers.forEach === 'function' && !Array.isArray(headers)) {
        headers.forEach(function (value, key) { out[key] = value; });
      } else if (Array.isArray(headers)) {
        headers.forEach(function (pair) { if (pair && pair.length >= 2) out[pair[0]] = pair[1]; });
      } else {
        for (var key in headers) {
          if (Object.prototype.hasOwnProperty.call(headers, key)) out[key] = headers[key];
        }
      }
    } catch (e) {}
    return out;
  }

  function bodyToString(body) {
    if (body === undefined || body === null) return null;
    if (typeof body === 'string') return body;
    try {
      if (body instanceof URLSearchParams) return body.toString();
      if (typeof FormData !== 'undefined' && body instanceof FormData) {
        var parts = [];
        body.forEach(function (value, key) {
          parts.push(key + '=' + (typeof value === 'string' ? value : '[blob]'));
        });
        return parts.join('&');
      }
      if (typeof Blob !== 'undefined' && body instanceof Blob) return '[Blob ' + body.size + 'B]';
      if (typeof ArrayBuffer !== 'undefined' && body instanceof ArrayBuffer) {
        return '[ArrayBuffer ' + body.byteLength + 'B]';
      }
      return JSON.stringify(body);
    } catch (e) {
      return '[' + (body && body.constructor ? body.constructor.name : typeof body) + ']';
    }
  }

  function deliver(payload) {
    try {
      var bridge = window.flutter_inappwebview;
      if (bridge && typeof bridge.callHandler === 'function') {
        bridge.callHandler(HANDLER, payload).catch(function () {});
        return true;
      }
    } catch (e) {}
    return false;
  }

  function post(payload) {
    if (!deliver(payload)) queue.push(payload);
  }

  function flush() {
    while (queue.length > 0) {
      var item = queue.shift();
      if (!deliver(item)) {
        queue.unshift(item);
        break;
      }
    }
  }

  window.addEventListener('flutterInAppWebViewPlatformReady', flush);
  setInterval(flush, 500);

  var origFetch = window.fetch;
  if (typeof origFetch !== 'function') return;

  window.fetch = function (input, init) {
    var started = Date.now();
    var url = typeof input === 'string' ? input : (input && input.url) || '';
    var method = (init && init.method) || (input && input.method) || 'GET';
    var reqHeaders = {};
    try {
      if (input && input.headers) reqHeaders = headersToObject(input.headers);
      if (init && init.headers) {
        var extra = headersToObject(init.headers);
        for (var key in extra) reqHeaders[key] = extra[key];
      }
    } catch (e) {}
    var reqBody = null;
    try { if (init && init.body !== undefined) reqBody = clip(bodyToString(init.body)); } catch (e) {}

    return origFetch.apply(this, arguments).then(function (response) {
      var payload = {
        source: 'fetch',
        url: (response && response.url) || url,
        method: method,
        requestHeaders: reqHeaders,
        requestBody: reqBody,
        status: response ? response.status : null,
        responseHeaders: headersToObject(response && response.headers),
        durationMs: Date.now() - started
      };
      try {
        var contentType = response && response.headers
          ? (response.headers.get('content-type') || '') : '';
        if (/json|text|xml|javascript|x-www-form-urlencoded/i.test(contentType)) {
          response.clone().text().then(function (text) {
            payload.responseBody = clip(text);
            post(payload);
          }).catch(function () { post(payload); });
        } else {
          post(payload);
        }
      } catch (e) {
        post(payload);
      }
      return response;
    }, function (error) {
      post({
        source: 'fetch',
        url: url,
        method: method,
        requestHeaders: reqHeaders,
        requestBody: reqBody,
        error: String(error),
        durationMs: Date.now() - started
      });
      throw error;
    });
  };
})();
''';

/// Keeps `target="_blank"` and `window.open` inside the headless page.
const String webViewNavigationHookScript = r'''
(function () {
  if (window.__gstoreNavHooked) return;
  window.__gstoreNavHooked = true;

  window.open = function (url) {
    if (url) location.href = String(url);
    return null;
  };

  document.addEventListener('click', function (event) {
    var target = event.target;
    var anchor = target && target.closest ? target.closest('a[target="_blank"]') : null;
    if (anchor && anchor.href) {
      event.preventDefault();
      location.href = anchor.href;
    }
  }, true);
})();
''';

String webViewContentTextScript({required bool readable}) {
  if (!readable) {
    return '''
(function () {
  var text = document.body ? document.body.innerText
      : (document.documentElement ? document.documentElement.innerText : '');
  return {
    title: document.title || '',
    url: location.href,
    text: text || ''
  };
})();
''';
  }
  return '''
(function () {
  if (!document.body) {
    return {title: document.title || '', url: location.href, text: ''};
  }
  var clone = document.body.cloneNode(true);
  var noise = clone.querySelectorAll(
    'script,style,noscript,iframe,svg,form,nav,footer,aside,header,button,' +
    '[role="navigation"],[aria-hidden="true"]'
  );
  for (var i = 0; i < noise.length; i++) {
    if (noise[i].parentNode) noise[i].parentNode.removeChild(noise[i]);
  }
  return {
    title: document.title || '',
    url: location.href,
    text: clone.innerText || ''
  };
})();
''';
}

const String webViewContentHtmlScript = '''
(function () {
  return {
    title: document.title || '',
    url: location.href,
    html: document.documentElement ? document.documentElement.outerHTML : ''
  };
})();
''';

String webViewClickScript(
  String selector,
  int index,
  bool synthetic,
) {
  return '''
(function () {
  var selector = ${jsonEncode(selector)};
  var index = $index;
  var synthetic = $synthetic;
  var elements = document.querySelectorAll(selector);
  var element = elements[index || 0];
  if (!element) {
    return {ok: false, error: '未找到元素', count: elements.length};
  }
  try { element.scrollIntoView({block: 'center', inline: 'center'}); } catch (e) {}
  var rect = element.getBoundingClientRect();
  if (!synthetic) {
    try {
      element.click();
      return {
        ok: true,
        method: 'click',
        url: location.href,
        title: document.title || ''
      };
    } catch (e) {}
  }
  var options = {
    bubbles: true,
    cancelable: true,
    view: window,
    clientX: rect.left + rect.width / 2,
    clientY: rect.top + rect.height / 2
  };
  var events = ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'];
  for (var i = 0; i < events.length; i++) {
    var name = events[i];
    try {
      var ctor = (name.indexOf('pointer') === 0 && typeof PointerEvent !== 'undefined')
        ? PointerEvent : MouseEvent;
      element.dispatchEvent(new ctor(name, options));
    } catch (e) {}
  }
  return {
    ok: true,
    method: 'synthetic',
    url: location.href,
    title: document.title || ''
  };
})();
''';
}

String webViewTypeScript(
  String selector,
  int index,
  String text,
  bool submit,
) {
  return '''
(function () {
  var selector = ${jsonEncode(selector)};
  var index = $index;
  var value = ${jsonEncode(text)};
  var submit = $submit;
  var elements = document.querySelectorAll(selector);
  var element = elements[index || 0];
  if (!element) {
    return {ok: false, error: '未找到元素', count: elements.length};
  }
  try { element.scrollIntoView({block: 'center'}); } catch (e) {}
  try {
    if (element.isContentEditable) {
      element.textContent = value;
      element.dispatchEvent(new Event('input', {bubbles: true}));
    } else if (element.tagName === 'SELECT') {
      element.value = value;
      element.dispatchEvent(new Event('change', {bubbles: true}));
    } else {
      var proto = element.tagName === 'TEXTAREA'
        ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      var descriptor = Object.getOwnPropertyDescriptor(proto, 'value');
      if (descriptor && descriptor.set) descriptor.set.call(element, value);
      else element.value = value;
      element.dispatchEvent(new Event('input', {bubbles: true}));
      element.dispatchEvent(new Event('change', {bubbles: true}));
    }
  } catch (e) {
    return {ok: false, error: String(e)};
  }
  if (submit && element.form) {
    try {
      if (element.form.requestSubmit) element.form.requestSubmit();
      else element.form.submit();
    } catch (e) {}
  }
  return {ok: true, url: location.href, title: document.title || ''};
})();
''';
}

String webViewWaitSelectorScript(String selector) => '''
(function () {
  return !!(document.querySelector(${jsonEncode(selector)}));
})();
''';

String webViewScrollScript(String selector, int x, int y) => '''
(function () {
  var selector = ${jsonEncode(selector)};
  var x = $x;
  var y = $y;
  if (selector) {
    var element = document.querySelector(selector);
    if (!element) return {ok: false, error: '未找到元素'};
    element.scrollIntoView({block: 'center', inline: 'center', behavior: 'smooth'});
    return {ok: true, url: location.href, title: document.title || ''};
  }
  window.scrollBy({left: x, top: y, behavior: 'smooth'});
  return {ok: true, url: location.href, title: document.title || ''};
})();
''';

const String webViewPageInfoScript = '''
(function () {
  return {
    url: location.href,
    title: document.title || '',
    readyState: document.readyState || '',
    textLength: document.body ? (document.body.innerText || '').length : 0
  };
})();
''';
