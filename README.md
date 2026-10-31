# Encore

An iPhone app that is just YouTube, built to use it as a music player.

- Opens YouTube (m.youtube.com) full screen: no address bar, no browser buttons
- Mini player like the YouTube app: swipe a video down and it shrinks to a bar above YouTube's tabs while you keep scrolling home, search or wherever you were, exactly where you left it
- Blocks ads: YouTube video ads are removed before the player loads them, and a block list covers common ad networks
- Keeps playing when you go to the Home Screen, switch apps or lock the phone
- Shows lock screen and Control Center controls: play/pause, next, previous, a scrubber and artwork
- Remembers your YouTube/Google login
- Sleep timer, swipe back, and AirPlay and Picture in Picture support
- Pauses for phone and VoIP calls (FaceTime, WhatsApp, ...) for the whole call and picks back up when it ends
- Pauses when headphones are unplugged or AirPods/Bluetooth disconnect (or when you take AirPods out), and stays paused

You need: a Windows PC, a USB cable for the iPhone, a free GitHub account and a free Apple ID.

---

## Part 1: Build the app (free, in the cloud, about 5 minutes)

You can't build iPhone apps on Windows, so GitHub's free Mac build machines do it for you.

1. Sign up at https://github.com (free).
2. Click **+ → New repository**. Name it `encore` and choose **Public**. Public repos get unlimited free build minutes. Private works too, but has a monthly limit (still enough for about 20 builds). Click **Create repository**.
3. On the new repo page click **uploading an existing file**. Drag in everything in this folder, including the `.github` folder, then click **Commit changes**.
   - Or, with Git installed:
     ```bash
     git init -b main
     ```
     ```bash
     git add . && git commit -m "Encore"
     ```
     ```bash
     git remote add origin https://github.com/YOUR-NAME/encore.git
     ```
     ```bash
     git push -u origin main
     ```
4. Open the **Actions** tab. If asked, click to enable workflows. The **Build IPA** run starts on its own (or click **Build IPA → Run workflow**).
5. When it turns green (about 5 min), click the run. Under **Artifacts**, download **Encore-ipa** and unzip it. You now have **`Encore.ipa`**.

## Part 2: Install it on your iPhone (free)

1. On the PC, install:
   - **Sideloadly**: https://sideloadly.io
   - **iTunes** and **iCloud**, *from Apple's website* (not the Microsoft Store versions). Sideloadly needs their iPhone drivers.
2. Plug the iPhone into the PC and tap **Trust** on the phone.
3. Open Sideloadly, drag `Encore.ipa` into it and type your Apple ID. Then click **Start** and enter your Apple ID password in Sideloadly when it asks. A spare Apple ID works too.
4. On the iPhone:
   - **Settings → Privacy & Security → Developer Mode → On** (the phone restarts; confirm **Turn On**).
   - **Settings → General → VPN & Device Management →** tap your Apple ID **→ Trust**.
5. Open **Encore** from the Home Screen and sign in to YouTube once. Your login is saved.

### Free Apple ID limits (Apple's rules, not the app's)

- The install is valid for **7 days**. To renew it, plug in the phone and drag the same `Encore.ipa` into Sideloadly again. Your login is kept. Sideloadly also has an automatic refresh option (Wi-Fi, PC on) so you don't have to do this by hand.
- A free Apple ID can have up to 3 sideloaded apps at once.
- A paid Apple Developer account ($99/yr) makes installs last a year. You don't need one.

---

## Using it

| What | How |
|---|---|
| Play music in the background | Start a video, then lock the phone or switch apps. It keeps playing. |
| Keep browsing while it plays | Swipe the video down (or the page down when it's at the top). It becomes the mini player and you're back where you were. |
| Bring the video back | Tap the mini player or swipe it up |
| Close the video | Tap ✕ on the mini player, or swipe it down |
| Lock screen / Control Center | Play/pause, next/previous, drag the scrubber |
| Sleep timer | Long-press the mini player → **Sleep Timer** |
| Turn ad blocking on/off | Long-press the mini player → **Block Ads**, or Settings → Encore |
| Links to other sites | Open in Safari over the app; close it to get back |

## Troubleshooting

- **An ad got through.** YouTube changes its ad system often. The ad logic is all in [`Encore/Resources/encore.js`](Encore/Resources/encore.js) and [`Encore/Resources/blocklist.json`](Encore/Resources/blocklist.json). Update them, push, and reinstall the new build.
- **Playback stopped after locking.** Make sure you're on the latest build (the app should resume within about a second on its own). Pressing play on the lock screen also resumes it in the background.
- **Google says "this browser may not be secure".** Go back and try again.
- **Sideloadly can't see the phone.** Reinstall iTunes from apple.com (not the Microsoft Store), reconnect the cable and tap Trust.

## Live development (no rebuild for script changes)

The ad blocking and playback logic is in `encore.js` and `blocklist.json`. You can change them live on the iPhone, from Windows, without rebuilding:

1. On the PC, in the repo folder, run `npm run dev`. It prints an address such as `172.20.10.5:8787`. The first time, allow Node.js through the Windows Firewall on **Private networks**.
2. In the app, long-press the mini player (play any video and swipe it down) → **Live Script Server**, type that address and tap **Connect**. Or type it in Settings → Encore → Live Script Server. The first time, allow **Local Network** access. The menu then shows **Live Script · Connected**.
3. Edit `Encore/Resources/encore.js` or `blocklist.json` and save. The app's pages reload with the new files. The page's `console.log` output and errors show up in the terminal.

The phone and the PC must be on the same network (the same Wi-Fi, or the PC on the iPhone's hotspot). Turn it off in the same menu. Changes to the Swift code still need a new build. When you're happy with your script changes, push them so the next build includes them.

`npm test` runs the page script tests.

## Project layout

```
project.yml                 XcodeGen spec (CI turns it into an Xcode project)
.github/workflows/build.yml Cloud build → unsigned Encore.ipa
Encore/App                  App entry point
Encore/Browser              The two YouTube pages (browse + player), WKWebView setup, ad blocking, links
Encore/Media                Audio session, calls/headphones, sleep timer (lock screen controls are iOS's own)
Encore/UI                   Main screen and the player panel (full screen / mini player)
Encore/Resources/encore.js  Injected page script: background play, ad removal, media bridge
Encore/Resources/blocklist.json  Network/cosmetic ad block rules
tests/encore.test.js        Playback/ad scenarios for the page script (run: npm test)
tools/dev-server.js         Live script server for the app (run: npm run dev)
```

If you have a Mac, run `brew install xcodegen && xcodegen generate`, open `Encore.xcodeproj`, choose your Apple ID under Signing & Capabilities and press Run.
