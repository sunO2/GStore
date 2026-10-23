// GStore script prelude — installed before the user channel script.
//
// Contract (mirrors lib/core/js/js_channel_runtime.dart `_hostPrefixJs`):
//   sendMessage(method, payloadJsonString) -> parsed envelope object
//   host.network.get/post, database.*, config.get, env.*, log.*, utils.call,
//   ui.call, core.call, alert.call
//
// `sendMessage` is deliberately synchronous. It returns the parsed envelope
// verbatim (never unwraps `.data`, never throws for `{ok:false}`) so `await
// sendMessage(...)` behaves exactly like the Dart bridge. Only malformed
// arguments throw, tagged CORE_E_SCRIPT_INVALID_ARGUMENT.

(function () {
  'use strict';

  var bridge = globalThis.__gstoreSendMessage;

  function invalid(message) {
    throw new Error('CORE_E_SCRIPT_INVALID_ARGUMENT: ' + message);
  }

  // Accept a JSON string (the Dart prefix always passes one) or an object/null.
  function normalize(payload) {
    if (payload === undefined || payload === null) {
      return null;
    }
    var parsed = payload;
    if (typeof payload === 'string') {
      try {
        parsed = JSON.parse(payload);
      } catch (error) {
        invalid('sendMessage payload is not valid JSON');
      }
    }
    if (parsed !== null && typeof parsed !== 'object') {
      invalid('sendMessage payload must be an object or null');
    }
    return parsed;
  }

  function sendMessage(method, payload) {
    var payloadJson = JSON.stringify(normalize(payload));
    return JSON.parse(bridge(String(method), payloadJson));
  }

  Object.defineProperty(globalThis, 'sendMessage', {
    value: sendMessage,
    writable: false,
    enumerable: false,
    configurable: false
  });

  var host = {
    network: {
      get: function (url, opts) {
        return sendMessage('host.network.get', JSON.stringify({ url: url, opts: opts || {} }));
      },
      post: function (url, opts) {
        return sendMessage('host.network.post', JSON.stringify({ url: url, opts: opts || {} }));
      }
    },
    database: {
      getAppsByChannel: function () {
        return sendMessage('host.database.getAppsByChannel', '{}');
      },
      getApp: function (appId) {
        return sendMessage('host.database.getApp', JSON.stringify({ appId: appId }));
      },
      insertApps: function (apps) {
        return sendMessage('host.database.insertApps', JSON.stringify({ apps: apps }));
      }
    },
    config: {
      get: function (key) {
        return sendMessage('host.config.get', JSON.stringify({ key: key }));
      }
    },
    env: {
      get: function (name) {
        return sendMessage('host.env.get', JSON.stringify({ name: name }));
      },
      all: function () {
        return sendMessage('host.env.all', '{}');
      },
      has: function (name) {
        return sendMessage('host.env.has', JSON.stringify({ name: name }));
      }
    },
    log: {
      info: function (msg) {
        return sendMessage('host.log.info', JSON.stringify({ msg: msg }));
      },
      error: function (msg) {
        return sendMessage('host.log.error', JSON.stringify({ msg: msg }));
      }
    },
    utils: {
      call: function (method, payload) {
        return sendMessage('host.utils.' + method, JSON.stringify(payload || {}));
      }
    },
    ui: {
      call: function (method, payload) {
        return sendMessage('host.native.call', JSON.stringify({ ns: 'ui', method: method, payload: payload || {} }));
      }
    },
    core: {
      call: function (method, payload) {
        return sendMessage('host.native.call', JSON.stringify({ ns: 'core', method: method, payload: payload || {} }));
      }
    },
    alert: {
      call: function (method, payload) {
        return sendMessage('host.native.call', JSON.stringify({ ns: 'alert', method: method, payload: payload || {} }));
      }
    }
  };

  Object.defineProperty(globalThis, 'host', {
    value: host,
    writable: false,
    enumerable: true,
    configurable: false
  });
})();
