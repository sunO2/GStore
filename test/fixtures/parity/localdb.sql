-- Deterministic LocalDb channel parity fixture.
-- Mirrors the Floor `apps` table shape used by lib/db/apps/AppInfo.dart.
-- FTS5 is intentionally NOT exercised by the parity harness; the Dart side of
-- the harness mirrors the DAO LIKE fallback (`name LIKE %q% OR des LIKE %q%`).
DROP TABLE IF EXISTS apps;

CREATE TABLE apps (
  appId TEXT PRIMARY KEY,
  name TEXT,
  user TEXT,
  repositories TEXT,
  icon TEXT,
  des TEXT,
  readme TEXT,
  category TEXT,
  extra TEXT
);

-- Row 1: exercises category JSON + extra.packageName. First appId -> getAppInfo.
INSERT INTO apps (appId, name, user, repositories, icon, des, readme, category, extra)
VALUES (
  'demo.alpha',
  'Demo Alpha',
  'alice',
  'alice/demo-alpha',
  'https://example.test/alpha.png',
  'A demo application for parity testing.',
  NULL,
  '["tools","demo"]',
  '{"packageName":"com.example.demoalpha","stars":12}'
);

-- Row 2: has readme; des matches the `demo` search term; no extra.
INSERT INTO apps (appId, name, user, repositories, icon, des, readme, category, extra)
VALUES (
  'beta.notes',
  'Beta Notes',
  'bob',
  'bob/beta-notes',
  'https://example.test/beta.png',
  'A notes app bundled with a demo mode.',
  '# Beta Notes
Second fixture row.',
  '["notes"]',
  NULL
);

-- Row 3: NULL readme/extra/category; does not match `demo`.
INSERT INTO apps (appId, name, user, repositories, icon, des, readme, category, extra)
VALUES (
  'gamma.timer',
  'Gamma Timer',
  'carol',
  'carol/gamma-timer',
  'https://example.test/gamma.png',
  'Countdown timer with alarms.',
  NULL,
  NULL,
  NULL
);
