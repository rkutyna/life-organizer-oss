# Connecting Google accounts

The organizer reads Google Calendar, Gmail and Google Tasks through **your own**
Google Cloud OAuth client. No shared app sits in the middle: each install talks to Google for
itself. You set this up once, in about ten minutes.

## 1. Create the OAuth client

In [Google Cloud Console](https://console.cloud.google.com/):

1. **Create a project**, e.g. "My organizer".
2. **Enable the APIs.** Under APIs & Services → Library, enable the **Google Calendar API** and the
   **Gmail API**, and the **Google Tasks API** for reminders.
3. **Set up the OAuth consent screen** (Google Auth Platform → Branding, Audience, Data access):
   - User type: **External**. Add your own Google address(es) as test users.
   - Data access: add the scopes `.../auth/calendar.readonly` and `.../auth/gmail.readonly`, and
     `.../auth/tasks` for reminders.
   - Audience: **Publish the app** ("In production"). While an app is in *Testing*, Google expires
     its sign-ins after 7 days, and the organizer would ask you to reconnect every week.
4. **Create credentials** → OAuth client ID → type **Web application**. Under *Authorized redirect
   URIs*, add the URI shown in the organizer at Settings → Connected accounts → Add account →
   Google account. It is your organizer's address followed by `/api/oauth/google/callback`.
   Google requires HTTPS for it, except for `http://localhost`.
5. **Copy the client ID and secret** into `.env`:

   ```bash
   GOOGLE_CLIENT_ID=1234567890-abc.apps.googleusercontent.com
   GOOGLE_CLIENT_SECRET=...
   PUBLIC_BASE_URL=https://organizer.example.com   # if a proxy hides the real address
   ```

   Then restart: `docker compose up -d`.

### "Google hasn't verified this app"

Your app is published but not verified, so Google shows a warning screen when you connect.
Choose *Advanced → Go to (your app)*. This is expected for a personal app. Google lets an
unverified app serve a small number of users, which covers you and your household.

Gmail's read-only scope is a *restricted* scope. Google would only demand a security assessment
if you wanted to verify the app for the public, which a personal install never needs.

## 2. Connect an account

Settings → Connected accounts → **Add account** → **Google account**. Choose what to read, then
continue to Google and approve. You come back to Settings with the account listed.

- One Google account appears once, however many features it grants. Connecting it again with
  more boxes ticked adds those scopes.
- Each Google account is connected separately.
- **Remove** in Settings deletes the stored tokens and asks Google to revoke the grant. You can
  also revoke it yourself at myaccount.google.com → Security → Third-party access.

## What is stored

The refresh and access tokens are encrypted with `ORGANIZER_SECRET_KEY` (see SETUP.md). The
address and the granted scopes are kept as plain settings. The organizer requests read-only
scopes for Calendar and Gmail. Tasks needs write access, because reminders sync both ways; it is
only requested when you tick Tasks (docs/REMINDERS.md).
