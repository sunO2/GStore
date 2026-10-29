-- V5: promote `local_db` membership to the writable `gstore` channel.
--
-- `local_db` becomes an internal catalog reader only; the user-facing channel
-- is `gstore`, whose saved metadata lives in `channel_apps('gstore')`. Every
-- statement is idempotent and the `apps` catalog is never mutated, so
-- re-running on an already-migrated database is a no-op.

INSERT INTO added_apps(channel_id, app_id, add_time, sort_order, is_enabled)
SELECT 'gstore', app_id, add_time, sort_order, is_enabled
FROM added_apps WHERE channel_id='local_db'
ON CONFLICT(channel_id, app_id) DO NOTHING;

INSERT INTO channel_apps(channel_key, app_id, name, user, repositories, apprepo,
                         icon, description, category, add_time, source_id, extra)
SELECT 'gstore', a.appId, a.name, COALESCE(a.user,''), COALESCE(a.repositories,''), NULL,
       COALESCE(a.icon,''), COALESCE(a.des,''), a.category,
       (SELECT aa.add_time FROM added_apps aa
         WHERE aa.channel_id='local_db' AND aa.app_id=a.appId),
       NULL, a.extra
FROM apps a
WHERE EXISTS (SELECT 1 FROM added_apps aa
               WHERE aa.channel_id='local_db' AND aa.app_id=a.appId)
ON CONFLICT(channel_key, app_id) DO NOTHING;

INSERT INTO added_app_tags(channel_id, app_id, tag, add_time)
SELECT 'gstore', app_id, tag, add_time FROM added_app_tags WHERE channel_id='local_db'
ON CONFLICT(channel_id, app_id, tag) DO NOTHING;

DELETE FROM added_app_tags WHERE channel_id='local_db';
DELETE FROM added_apps       WHERE channel_id='local_db';

PRAGMA user_version = 5;
