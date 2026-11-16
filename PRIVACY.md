# Privacy Policy — MeTube for TerraMaster TOS (`metube`)

**Last updated:** 17 November 2026
**Data controller / contact:** Moechz — moechz@163.com

This policy covers the TOS application `metube` (the “app”) and its packaging.

## 1. Summary

- The app runs **entirely on your NAS**. The developer does not receive, collect or have
  access to your data.
- No telemetry, no analytics, no account and no cloud service operated by the developer.
- The app contacts only the services **you configure**.

## 2. What data is processed

`/Volume1/DockerAppData/metubedocker/downloads` (downloaded media and the queue database).

That is the application's configuration, database, caches and logs, plus the files you
create with it. Nothing is uploaded to the developer.

## 3. Retention period

- **Application data:** kept until **you** delete it. There is no automatic expiry and no
  upload.
- **Logs:** rotated or size-limited by the application (or by journald for the service).
- **Cache:** rebuilt on demand; safe to delete at any time.
- **Website/server logs (moechz.com):** short-lived operational logs, not used for profiling.

## 4. Your rights and the deletion channel

| Right | How |
|---|---|
| Access / export | Copy the data location listed above — it is the complete state. |
| Correct | Change the values in the app's own web UI or configuration file. |
| Delete | `apt purge` (or the App Center's “delete data” option) removes the data; on Docker-backed packages remove the application data folder. |
| Assistance | Email **moechz@163.com** with the subject “MeTube data request”; a reply follows within 30 days. |

## 5. Security measures

- The service runs as its own unprivileged system user, never as root.
- Only the ports it needs are exposed; the web UI is reachable through the TOS reverse
  proxy where applicable.
- The package is rebuilt when upstream ships security fixes.
- If you expose the UI outside the LAN, put it behind a TLS reverse proxy and keep the app
  updated.

## 6. Third-party sharing and API disclosure

The developer shares nothing. The app contacts only the endpoints **you configure**:

| Service | Endpoint | Data sent | Destination / region |
|---|---|---|---|
| Services you configure in the app | the address you enter | only the data that feature needs | normally your own LAN or the provider you chose |
| Update check (if enabled) | the upstream project's release feed | current version string | GitHub, US |

No data is sold or shared with advertisers. There is no third-party analytics SDK.

## 7. Children

The app is a self-hosted utility and is not directed at children.

## 8. Changes

Material changes are published in this file and reflected in the “Last updated” date.

## 9. Contact

Moechz — **moechz@163.com** — <https://www.moechz.com/privacy.html>
