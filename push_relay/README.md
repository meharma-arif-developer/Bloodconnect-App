# Free push notifications (no Firebase Blaze plan)

Firebase Cloud Messaging itself is free. What normally costs money is the *server code* that sends the message.
This small relay runs that code on **Cloudflare Workers (free plan)** instead.

> Status: the relay passes 8 offline tests with fake Google servers (`npm test`).
> It has NOT been tested against the real Google / Cloudflare services yet. Cloudflare's free-plan limits and
> rules can change - check their pricing page. Push on iPhone additionally needs an Apple developer account.

## One-time setup (about 15 minutes)

### A. Make a restricted Google key for the relay
1. Google Cloud Console (console.cloud.google.com) > select project `bloodconnect-f8c69`.
2. IAM & Admin > Service Accounts > **Create service account**, name it `push-relay`.
3. Give it ONLY these roles: **Cloud Datastore User** and **Firebase Cloud Messaging API Admin**.
4. Open it > Keys > Add key > JSON. Save the file OUTSIDE the project folder (for example `C:\keys\push-relay.json`).
   Do not use your admin key for this and do not share the file.

### B. Deploy the relay
```powershell
cd C:\FlutterProjects\blood_connect\push_relay
npx wrangler login
npx wrangler secret put SERVICE_ACCOUNT_JSON
```
When asked for the value, paste the ENTIRE contents of `push-relay.json`. Then:
```powershell
npx wrangler deploy
```
It prints a web address like `https://bloodconnect-push-relay.yourname.workers.dev`.

### C. Tell the app
Open `lib/config/app_config.dart` and set:
```dart
static const String pushRelayUrl = 'https://bloodconnect-push-relay.yourname.workers.dev';
```
Run the app again. Both phones must log in once and allow notifications.

### D. Redeploy rules (token storage unchanged, but do it once with the latest rules)
```powershell
cd C:\FlutterProjects\blood_connect
firebase deploy --only firestore:rules
```

## What it does
| App action | Push sent to |
|---|---|
| Receiver creates a blood request | Up to 30 matching donors (same blood group, available, same country + city, not blocked, notifications on) |
| Receiver sends a request to one donor | That donor |
| Donor accepts / declines / completes | The receiver |

Safety: the relay checks the caller's Firebase login, checks in Firestore that the caller really owns the request,
sends each push only once, refuses suspended users, and the text is generic (no blood group, hospital or phone).
