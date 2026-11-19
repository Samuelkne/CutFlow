# CutFlow

An auto-editor for UGC on iPhone. Drop up to 6 clips into numbered slots (Clip 1 is the opener; empty slots are skipped). The app cuts out the silences and dead air, keeps the clips in slot order, and can open on a short hook teaser. It adds jump-cut punch-in zooms and caps the edit at your chosen length (15s, 30s, 60s or Full). **Split Screen** (the Split tab) makes clone videos: film the same person 2 or 3 times in different zones with on-camera guide lines, then the takes are blended with feathered edges. You choose where the lines go and how soft they are. Then save the vertical 9:16 MP4 to Photos or share it to TikTok or Shorts.

## 1. Build it on GitHub (free)
1. Go to github.com and click **New repository**. Name it `CutFlow`, make it **Public** (public repos get unlimited free Mac build minutes), and create it.
2. Click **uploading an existing file**. Drag in everything from this folder, including the `.github` folder, then click **Commit**.
3. Open the **Actions** tab. The "Build iPhone app" run starts on its own and takes about 5 minutes.
4. When it shows a green check, open the run and download **CutFlow-ipa** under *Artifacts*. Unzip it to get `CutFlow.ipa`.

## 2. Put it on your iPhone (Windows, free)
1. Install **iTunes** and **iCloud** from Apple's website. Don't use the Microsoft Store versions; Sideloadly needs the ones from Apple.
2. Install **Sideloadly** from sideloadly.io.
3. Plug in your iPhone and tap **Trust**. Drag `CutFlow.ipa` into Sideloadly, enter your Apple ID, and click **Start**.
4. On the iPhone, open **Settings → Privacy & Security → Developer Mode**, turn it on, and restart the phone.
5. Then open **Settings → General → VPN & Device Management**, tap your Apple ID, and tap **Trust**.

With a free Apple ID the app expires after **7 days**. To renew it, run Sideloadly again with the same .ipa. Your clips stay safe in Photos.

## Changing the app
Edit the files in `CutFlow/` on GitHub. Every commit rebuilds the .ipa automatically.
