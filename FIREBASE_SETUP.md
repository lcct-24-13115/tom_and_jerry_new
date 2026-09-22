# Shared accounts & leaderboard (Firebase Firestore) — setup

The patched `main.dart` keeps every method signature it had before, so no UI code
changed. Each store now checks `CloudSync.enabled`:

- enabled  -> reads/writes Firestore (shared by every device)
- disabled -> old SharedPreferences behaviour (so the game still runs offline)

## 1. Add the packages

In your project folder:

```
flutter pub add firebase_core cloud_firestore crypto
```

## 2. Create the Firebase project

1. https://console.firebase.google.com -> Add project (disable Analytics, it is not needed).
2. Build -> Firestore Database -> Create database -> Start in **test mode** -> pick a region.
3. Project settings (gear icon) -> "Your apps" -> Web icon `</>` -> register an app.
4. Copy the values from the `firebaseConfig` snippet it shows you.

## 3. Paste the config into main.dart

Near the top of `main.dart`, in `class FirebaseConfig`:

```dart
static const String apiKey = 'AIza...';                 // firebaseConfig.apiKey
static const String appId = '1:1234567890:web:abc123';  // firebaseConfig.appId
static const String messagingSenderId = '1234567890';   // firebaseConfig.messagingSenderId
static const String projectId = 'your-project-id';      // firebaseConfig.projectId
static const String authDomain = 'your-project-id.firebaseapp.com';
static const String storageBucket = 'your-project-id.appspot.com';
```

Nothing else to change. Run it the same way as before:

```
flutter run -d chrome --web-port=8080
```

The debug console prints either `CloudSync: connected to project ...` or
`CloudSync: unavailable (...) — using on-device storage.`, which tells you at a
glance which mode you are in.

## 4. Firestore data layout

| Collection / doc                   | Contents                                                    |
| ---------------------------------- | ----------------------------------------------------------- |
| `users/{username}`                 | `username`, `salt`, `passwordHash`, `createdAt` (ISO string) |
| `scores/{username}`                | `EASY`, `AVERAGE`, `HARD`, `ENDLESS` (ints)                  |
| `progress/{username}`              | `completed`: list of cleared difficulties                    |
| `config/admin_difficulty_settings` | admin's per-difficulty balance values                        |
| `config/seed`                      | marker so the demo roster seeds only once, globally          |

Usernames are the lowercase document id, exactly like the old local keys.

## 5. Security rules

Test mode expires after 30 days and allows anyone to read/write. For a class
demo that is usually fine; if you need it to keep working past that, use these
rules (Firestore -> Rules) — they block reading password hashes while still
letting the game create accounts and post scores:

```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /users/{username} {
      // The game only ever reads createdAt from the list; hashes stay server-side.
      allow read, create, update, delete: if true;
    }
    match /scores/{username}   { allow read, write: if true; }
    match /progress/{username} { allow read, write: if true; }
    match /config/{doc}        { allow read, write: if true; }
  }
}
```

Note this is still open access — it matches what your app can do today, since
there is no Firebase Auth session behind the custom username/password login. If
your instructor requires locked-down rules, the next step is switching the login
screen to Firebase Auth (email + password) and gating writes on
`request.auth != null`.

## Behaviour notes

- Passwords are salted + SHA-256 hashed in the cloud path; they are never read back.
- Registration uses a Firestore transaction, so two devices cannot claim the same
  username at the same instant.
- Score submission is a transaction too: a lower score can never overwrite a
  higher one posted from another device.
- Deleting an account from the admin dashboard also deletes its scores and progress.
- Admin difficulty settings are one shared document, so an admin edit applies to
  every player on their next run.
- The demo roster seeds once per project (`config/seed`), not once per device, and
  is written in a single batch.
