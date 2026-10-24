// Dedicated real-engine fixture for the Plan-Todo 7 Rust-lane parity test.
//
// Why this file exists: `assets/channels/example.js` is the product's built-in
// template and implements only getAllApps/searchApps/getAppInfo/getAppDetail/
// checkAppUpdate/checkUpdate/doUpdate. It does NOT implement getConfig,
// sendMessage or host.ui.call, so it cannot prove those contracts. This fixture
// is test-only and implements all three contracts.
//
// ScriptApi only dispatches the allowlisted method names (`getConfig`,
// `getAllApps`, `checkAppUpdate`, ...). A literal `sendMessage` method is not a
// dispatch target — `sendMessage` is the JS host bridge helper. So the fixture
// exposes the sendMessage and host.ui.call contracts through real allowlisted
// entry points:
//   getConfig      -> the config contract (see getConfigEntry)
//   getAllApps     -> the sendMessage contract (see sendMessageRoundtrip)
//   checkAppUpdate -> the host.ui.call contract (see uiCallRoundtrip)
//
// Every asserted value is composed inside JavaScript from the params or from a
// host round-trip: nothing is a constant the Rust harness injects.
//   getConfig      -> version/proxy are built from params.major/minor/host and
//                     `echo` is `'cfg:' + params.token`.
//   sendMessage    -> reads `channel.region` through host.config.get and
//                     appends `'@' + params.token`.
//   host.ui.call   -> calls host.ui.call('showVersionPicker'), then tags the
//                     responder's env with `'ui:' + params.token`.
function getConfigEntry(params) {
  return {
    version: String(params.major) + '.' + String(params.minor),
    proxy: 'http://' + String(params.host) + ':7890',
    echo: 'cfg:' + String(params.token)
  };
}

function sendMessageRoundtrip(params) {
  var res = sendMessage('host.config.get', JSON.stringify({ key: 'channel.region' }));
  var value = res && res.ok === true ? res.data : 'missing';
  return String(value) + '@' + String(params.token);
}

function uiCallRoundtrip(params) {
  var ui = host.ui.call('showVersionPicker', { title: '选择版本' });
  var env = ui && ui.ok === true && ui.data ? ui.data.env : null;
  return { env: env, tag: 'ui:' + String(params.token) };
}

function main(method, params) {
  params = params || {};
  if (method === 'getConfig') {
    return { ok: true, data: getConfigEntry(params) };
  }
  if (method === 'getAllApps') {
    return { ok: true, data: sendMessageRoundtrip(params) };
  }
  if (method === 'checkAppUpdate') {
    return { ok: true, data: uiCallRoundtrip(params) };
  }
  return null;
}
