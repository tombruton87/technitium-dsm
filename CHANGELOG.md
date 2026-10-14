# Changelog

## 1.0.2 — 2026-10-14

- The Network and HTTPS settings on the Site address tab no longer jump back to
  the saved value a moment after you change them, before you can press Save.
- **Show password** on the Setup tab: the package keeps the admin password it
  last made (in its own folder, for DSM administrators only) and shows it again
  with a Copy button. Installs from earlier versions have nothing kept until
  New password makes one.

## 1.0.1 — 2026-10-14

- DNS listens on the NAS's LAN address instead of every address. Many
  Synology models keep `127.0.0.1:53` for DSM itself, and 1.0.0 couldn't start
  alongside it ("address already in use").
- If port 53 is taken on that address, the package stops with one sentence
  naming what holds it, instead of retrying. The support report lists what
  listens on port 53.
- A **Network** setting on the Site address tab: the NAS's own network (new
  installs), where Technitium's logs show each device's address, or Docker's
  network, where every device shows as Docker's gateway. Changing it makes the
  container again. Installs from 1.0.0 stay on Docker's network until changed.

## 1.0.0 — 2026-10-13

First release. Technitium DNS Server 15.6.1 in Container Manager, answering DNS
on port 53 (TCP and UDP). The installer warns if port 53 is already taken on
the Synology, and the log says so plainly if DSM's DNS Server package has it.
Your admin password is set at the first start and shown once; the package has
an API token of its own.

The DSM window adds:
- **Blocking:** the last 24 hours' figures, blocking on and off, pause with a
  timer, blocklists (add, remove, fetch now), sites always allowed or blocked,
  and the sites blocked most.
- **Zones:** local names for your own devices (nas.home → the NAS), A, AAAA and
  CNAME, with the zone made for you.
- **Resolvers:** forward to Cloudflare, Quad9, Google or your own servers,
  encrypted (DNS-over-HTTPS or DNS-over-TLS) or plain, or resolve recursively.
- **Setup:** router and DHCP steps, a note on encrypted DNS, and a new
  password.
- **Site address:** HTTPS for the web console with DSM's certificate.

Also included: backups (the whole config folder, copied with Technitium
stopped cleanly for a few seconds), restore, pinned-image updates and removal.
