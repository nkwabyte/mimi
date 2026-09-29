# Licensing plan: free CLI, paid Mac app

Status: proposal, 2026-09-28. Decisions marked **Decide** need the owner.

## 1. Goal

- The `mimi` command-line tool stays free and open source.
- The Mac app (the GUI in `gui/`) is paid: a one-time Lifetime licence, or a Monthly subscription.
- Licence keys work offline, are hard to forge, and never need the app to send scan data anywhere.
- One small server, on the Hostinger VPS, issues and renews keys. The app keeps working if that server is down.

What the app already has (merged with this plan):

- A licence section in Settings: status, key entry, Activate, Remove, and buy buttons.
- Offline key verification with Ed25519 (`gui/Mimi/Mimi/License/`).
- Key storage in the login keychain.
- A 7-day grace period for monthly keys past their expiry.
- Nothing is locked yet. Gating is phase 4 below.

## 2. Before anything else: the repository is MIT

Everything in this repository, the GUI included, is under the MIT licence. Anyone may build the app from source, remove the licence check, and share the result. That is allowed by the licence, and it cannot be taken back for code already published under MIT.

Options:

| Option | What it means | Trade-off |
|---|---|---|
| A. Move the GUI to a private repository (recommended) | `nkwabyte/mimi` keeps the engine (MIT). A new private repo `nkwabyte/mimi-mac` holds the app and pulls the engine in at build time. | Clean separation. The published GUI code stays MIT, but new app work is closed. |
| B. Relicense `gui/` for future versions | Keep one repo, and put `gui/` under a source-available licence (for example PolyForm Noncommercial, or a custom EULA). | Everything stays in one place, but the check is easy to remove from a build, and mixed licences in one repo confuse contributors. |
| C. Keep everything MIT, sell convenience | Sell the signed, notarized, auto-updating build. The source stays open. | Simplest and honest, but expect some people to build it themselves. Many open-source Mac apps work this way. |

**Decide:** A, B or C. The rest of this plan works with any of them. With C, the licence is a courtesy check rather than protection.

## 3. Pricing

Requested: USD 20 to 50 one-time, or USD 5 a month.

Recommendation:

- **Lifetime: USD 29.** This is the middle of the market for Mac utilities. Cover all 1.x updates; a future 2.0 can be a paid upgrade with a discount.
- **Monthly: USD 5.** Consider also a yearly plan at USD 39 (two months free). It costs little to add now and lowers churn.
- **Trial: 14 days, full features, no key needed.** A cleaner is judged by its first scan. See phase 4.
- A lifetime licence covers 2 Macs, and a subscription 2 Macs (`seats` in the key).

**Decide:** final prices, whether to add yearly, the trial length, and the number of seats.

The prices shown in the app are `LicenseConfig.lifetimePrice` and `monthlyPrice`. The checkout page is what the customer actually pays.

## 4. Taking payments: use a merchant of record

Selling software to people in many countries means collecting and filing VAT or sales tax in each of them. A merchant of record (MoR) sells on your behalf, handles tax, invoices and refunds, and pays you out.

| Provider | Model | Fee (approximate) | Notes |
|---|---|---|---|
| **Lemon Squeezy** (recommended to start) | MoR | 5% + USD 0.50 | Built-in licence keys and subscription webhooks; quick to set up; pays out to many countries. |
| **Paddle** | MoR | 5% + USD 0.50 | Established, strong for subscriptions; stricter onboarding. |
| **Stripe** | Payments only (not MoR) | 2.9% + USD 0.30 | Cheapest, but you register for and file tax yourself (Stripe Tax helps; it costs extra). |

Recommendation: start with Lemon Squeezy or Paddle. Check that the provider pays out to your country and bank before building anything. That is the usual blocker.

The provider's own licence-key feature is not used as the key. Our server issues the signed key described below, so the app never depends on the provider staying online, and switching providers later does not invalidate keys.

**Decide:** the provider.

## 5. How it fits together

```
 Customer ── checkout ──▶ Payment provider (MoR)
                              │ webhook: order paid / subscription renewed / cancelled / refunded
                              ▼
                     Licence server (Hostinger VPS)
                     - verifies the webhook signature
                     - creates or updates the licence in the database
                     - signs a key with the Ed25519 private key
                     - emails the key (and shows it on the account page)
                              ▲
            activate / refresh │ (HTTPS, small JSON, no scan data)
                              │
                         Mimi.app
                         - verifies keys offline with the public key
                         - refreshes monthly keys before they expire
```

## 6. The key format (already implemented in the app)

```
MIMI1.<payload>.<signature>
```

- `payload`: base64url (no padding) of compact JSON with sorted keys:
  ```json
  {"email":"person@example.com","expires":"2026-10-28T12:00:00Z","id":"lic_01J…","issued":"2026-09-28T12:00:00Z","plan":"monthly","seats":2,"v":1}
  ```
  - `plan` is `lifetime` or `monthly`.
  - `expires` is present only for subscriptions.
  - Dates are UTC, `YYYY-MM-DDTHH:MM:SSZ`.
- `signature`: base64url of the Ed25519 signature of the exact payload bytes.
- `MIMI1` is the format version. A future format can use `MIMI2`; the app says "update the app" for versions it does not know.

Why this design:

- **The app cannot mint keys.** It holds only the 32-byte public key (`LicenseConfig.publicKeyBase64`).
- **Offline.** Checking a key needs no network, and CryptoKit does it natively.
- **Hard to forge.** Changing any byte of the payload breaks the signature. The app tests this with a spliced payload.
- **Readable.** Support can decode the payload to see who a key belongs to.

Reference signer (Python, the `cryptography` package). The app's test suite verifies a key made by exactly this code:

```python
import base64, json
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

def b64u(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

def make_key(private_key: Ed25519PrivateKey, payload: dict) -> str:
    data = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()
    return "MIMI1." + b64u(data) + "." + b64u(private_key.sign(data))
```

Key pair (do this once, offline, on your own Mac, not on the VPS):

```python
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization
import base64
k = Ed25519PrivateKey.generate()
open("mimi-licence-private.pem", "wb").write(k.private_bytes(
    serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
    serialization.BestAvailableEncryption(b"a long passphrase")))
print(base64.b64encode(k.public_key().public_bytes(
    serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode())
```

The printed value goes into `LicenseConfig.publicKeyBase64`. Keep the encrypted PEM, and a paper or password-manager copy of the passphrase, somewhere safe. **Losing the private key means no new keys can be made for existing app builds. Leaking it means anyone can make keys.**

## 7. The licence server

Small and boring on purpose.

### Stack on the Hostinger VPS

| Part | Choice | Why |
|---|---|---|
| OS | Ubuntu 24.04 LTS | Long support, standard |
| App | Python 3.12 + FastAPI (or Go, if you prefer one static binary) | Tiny code base; the signer above drops in |
| Database | SQLite in WAL mode to start; Postgres if you ever need more | One file, easy backups; thousands of licences are nothing |
| Web | Caddy | Automatic HTTPS certificates, simple config |
| Process | systemd unit, running as its own user | Restarts on failure, no root |
| Email | Transactional provider (Postmark, Resend or Amazon SES) | VPS IPs have poor mail reputation; do not send from the VPS directly |
| Backups | Nightly SQLite `.backup` copied off the VPS (for example an object-storage bucket) | Losing licence records hurts customers |

Domain: for example `licence.<yourdomain>` for the API, and `<yourdomain>/account` for the customer page.

### Data

```
licences(id, email, plan, status[active|cancelled|refunded|revoked],
         seats, provider, provider_customer_id, provider_subscription_id,
         created_at, current_period_end)
activations(id, licence_id, machine_hash, machine_name, created_at, last_seen_at)
events(id, provider_event_id UNIQUE, type, payload_json, received_at)   -- webhook log, idempotency
```

### Endpoints

| Method and path | Who calls it | What it does |
|---|---|---|
| `POST /webhooks/<provider>` | Payment provider | Checks the provider's signature and ignores repeats (via `events.provider_event_id`). Creates the licence on purchase, extends `current_period_end` on renewal, and marks cancel or refund. Emails the key on first purchase. |
| `POST /v1/activate` | App | Sends `{key, machine_hash, machine_name}`. Checks the key, the licence status and free seats; records the activation; returns a fresh key (for monthly plans, with the current expiry). |
| `POST /v1/refresh` | App | Sends `{key, machine_hash}`. Returns a new key with an extended `expires` while the subscription is paid; returns `revoked` for refunded or revoked licences. |
| `POST /v1/deactivate` | App ("Remove Licence") | Frees the seat. |
| `POST /v1/recover` | Account page | Emails the key again to the purchase address (rate-limited). |
| `GET /healthz` | Monitoring | Up check. |

`machine_hash` is SHA-256 of the Mac's hardware UUID (`IOPlatformUUID`) with an app-specific salt. It identifies a seat without revealing the UUID.

### Subscriptions

- A monthly key carries `expires` = end of the paid period + 3 days.
- The app calls `/v1/refresh` when less than 5 days remain, and at most once a day.
- If the server is unreachable, the app keeps working for `LicenseConfig.offlineGraceDays` (7) past `expires`, showing "renewal pending". This is implemented.
- On cancellation, the subscription runs to the end of the paid period, then refresh stops extending it.

### Refunds and revocation

- Monthly keys expire on their own, and refresh returns `revoked`.
- Lifetime keys never expire, so revoking one needs the app to check in. The app calls `/v1/refresh` for lifetime licences about every 30 days when online. If the answer is `revoked`, it clears the key. Offline use is never blocked for a lifetime licence.
- Keep a revocation list small: only refunds and chargebacks.

### Security checklist for the server

- The private key is loaded from an encrypted file or environment secret readable only by the service user. Never commit it; never log keys.
- Verify every webhook signature and reject old timestamps.
- Rate-limit `activate`, `refresh` and `recover` per IP and per licence.
- HTTPS only (Caddy). Allow only ports 22, 80 and 443 in the firewall; use SSH keys, not passwords; turn on unattended security upgrades.
- Store the minimum personal data: email, provider ids and machine hashes. Write a privacy note for the website (see `SECURITY.md` for the app's own statement).

## 8. App work still to do

- **Online calls:** `activate`, `refresh` and `deactivate` in a small `LicenseClient`, the server URL in `LicenseConfig`, the refresh schedule described above, and the machine hash.
- **Trial:** the first launch date is stored in the keychain, so reinstalling does not reset it. Settings shows the days left.
- **Gating (decide what is paid):** suggested:
  - Free forever: scanning, the Overview, and opening features in Terminal.
  - Paid (or trial): the History screen's delete, purge and Clear All, and future in-app cleaning.
  - When unlicensed, paid actions show a short sheet with the two plans.
  - Never block the CLI, and never delete or hide data because a licence lapsed.
- **Distribution:** a paid app must be signed with a Developer ID and notarized, or macOS will warn buyers. That needs the Apple Developer account (USD 99 a year), the same prerequisite as the signed root launcher in the system review.
- **Updates:** Sparkle for in-app updates, with its own EdDSA signing key, separate from the licence key.

## 9. Phases

| Phase | Work | Needs |
|---|---|---|
| 0 | Decide section 2 (repo licence), prices, trial, seats, provider | Owner |
| 1 | Generate the key pair offline; put the public key in `LicenseConfig`; issue test keys with the Python signer | Nothing else |
| 2 | VPS: Ubuntu, Caddy, the service, SQLite and backups; `/healthz`; the webhook with a test-mode store | Hostinger VPS, a domain |
| 3 | Provider: products (Lifetime, Monthly), checkout links in `LicenseConfig`, webhook secret, email sending | Provider account, payouts verified |
| 4 | App: `LicenseClient` (activate, refresh, deactivate), trial, gating sheet | Phases 1 to 3 |
| 5 | Developer ID signing, notarization, Sparkle updates, website with pricing, terms, privacy and refund policy | Apple Developer account |
| 6 | Launch: test purchase, refund and renewal end to end in the provider's test mode, then live | All of the above |

## 10. Rough running costs

| Item | Cost |
|---|---|
| Hostinger VPS (KVM 1 or 2) | about USD 5 to 10 a month |
| Domain | about USD 10 to 15 a year |
| Transactional email | free tier at first |
| Apple Developer Program | USD 99 a year |
| Payment provider | about 5% + USD 0.50 per sale |

At USD 29 a sale, the provider takes about USD 1.95, leaving about USD 27.

## 11. Decisions needed

1. Repository licence approach: A, B or C (section 2).
2. Final prices; whether to add a yearly plan; trial length; seats per licence.
3. Payment provider, after confirming it pays out to your country.
4. Server language: Python/FastAPI or Go.
5. What is free and what is paid in the app (section 8, gating).
6. Domain name for the API, account page and website.
