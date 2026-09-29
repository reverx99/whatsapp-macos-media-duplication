# WhatsApp for Mac re-downloads the same media tens of thousands of times

A single one-on-one chat grew to **99 GB** on disk: **102,988 files**, but only
**24 unique file sizes**. The count kept going up while I was measuring it.

- [TL;DR](#tldr)
- [Am I affected?](#am-i-affected)
- [Environment](#environment)
- [Investigation](#investigation)
- [Observed behavior vs. possible cause](#observed-behavior-vs-possible-cause)
- [Impact](#impact)
- [Workaround](#workaround)
- [Status](#status)
- [Disclaimer](#disclaimer)

## TL;DR

- My Mac got slow. The cause wasn't CPU or RAM. The disk was 93% full.
- 112 GB of that was WhatsApp's group container, and **99 GB came from one chat's media folder**.
- That folder held 102,988 files, but only **24 distinct file sizes**. The same few
  attachments had been written to disk over and over, more than 10,000 times each.
- Between two measurements a few minutes apart, every one of the top repeated sizes
  went up by exactly one copy. The loop was still running during the investigation.
- I can't see WhatsApp's code, so I don't claim a root cause. The pattern looks like
  a download/retry loop that never marks the attachment as saved.

## Am I affected?

Check how big WhatsApp's media folder is:

```zsh
du -sh ~/Library/Group\ Containers/group.net.whatsapp.WhatsApp.shared/Message/Media
```

If that's much bigger than you'd expect, run the detector:

```zsh
git clone https://github.com/reverx99/whatsapp-macos-media-duplication.git
cd whatsapp-macos-media-duplication
less check.sh        # read it first; it's short
./check.sh           # add --hash to confirm the duplicates are identical
```

`check.sh` is **read-only**. It never deletes, moves or writes anything. It never prints
folder names (those contain phone numbers and chat IDs). Folders show up as `chat_1`,
`group_1`, `status_1` and so on, so the output is safe to paste in a public issue.

For each media folder it reports:

| Column       | Meaning                                                              |
|--------------|----------------------------------------------------------------------|
| `SIZE`       | Total size of the files in the folder                                |
| `FILES`      | Number of files                                                      |
| `UNIQ_SIZES` | Number of distinct file sizes                                        |
| `RATIO`      | `FILES / UNIQ_SIZES`                                                 |
| `NEW_1H`     | Files written in the last 60 minutes                                 |
| `FLAG`       | `SUSPICIOUS` when `FILES > 1000` **and** `RATIO >= 20`               |

**Why these thresholds:** photos, voice notes and documents almost never share an exact
byte size, so a healthy chat has a ratio close to 1 (usually below 2). A ratio of 20
means that, on average, every distinct size shows up 20 times. That doesn't happen in
normal use. The affected chat here had a ratio of about 4,300 (102,988 / 24). The
1,000-file minimum keeps small chats with a few repeated stickers from being flagged.
You can change both with `MIN_FILES=... MIN_RATIO=... ./check.sh`.

Exit status: `0` nothing suspicious, `1` at least one suspicious folder, `2` usage or path error.

> On recent macOS versions, reading another app's container may show a
> "Terminal would like to access data from other apps" prompt, or fail with
> *Operation not permitted*. Allow the prompt, or give your terminal Full Disk Access in
> System Settings > Privacy & Security.

Output from my machine:

```text
[TODO: paste the output of ./check.sh --hash here]
```

## Environment

| | |
|---|---|
| Hardware | MacBook Air (M1), 8 GB RAM, 256 GB SSD (228 Gi data volume) |
| macOS | [TODO] |
| WhatsApp for Mac | [TODO version / build] |
| Install source | [TODO App Store or direct download] |
| Shell | zsh, BSD userland |

## Investigation

All commands are standard macOS tools. Paths use `~`, and chat folder names are redacted.
Screenshots are in [`evidence/`](evidence/).

### 1. Symptom

The Mac felt slow in general. Spotlight (<kbd>Cmd</kbd>+<kbd>Space</kbd>) and app
launches were noticeably laggy.

### 2. CPU: fine. Swap: not fine.

`htop` showed a load average of about 3.4–4.4 on 8 cores, so CPU wasn't the bottleneck.
But swap was at **3.24 G of 4 G**. Uptime was 14 days.

![htop](evidence/01-htop.png)

### 3. Memory pressure: green

Activity Monitor showed green memory pressure: 6.37 GB used, 2.23 GB compressed,
3.18 GB swap. RAM usage was high but not the root cause.

![Activity Monitor memory tab](evidence/02-activity-monitor.png)

### 4. Spotlight indexing: ruled out

```zsh
mdutil -sa
```

No volume was actively indexing.

### 5. The disk was almost full

```zsh
df -h /System/Volumes/Data
```

```text
Size   Used   Avail  Capacity     (other columns trimmed)
228Gi  173Gi  13Gi   93%
```

macOS needs free space for swap files and caches. With only 13 Gi free on a 228 Gi
volume, heavy swap use slows down the whole system.

![df output](evidence/03-df.png)

### 6. Narrowing it down

```zsh
du -sh ~/* ~/Library/* 2>/dev/null | sort -h | tail -20
du -sh ~/Library/Group\ Containers/* 2>/dev/null | sort -h | tail -10
du -sh ~/Library/Group\ Containers/group.net.whatsapp.WhatsApp.shared/* | sort -h | tail -5
du -sh ~/Library/Group\ Containers/group.net.whatsapp.WhatsApp.shared/Message/Media/* | sort -h | tail -10
```

```text
~/Library                                            168G
└─ Group Containers                                  114G
   └─ group.net.whatsapp.WhatsApp.shared             112G
      └─ Message                                     112G   (ChatStorage.sqlite is only 160M)
         └─ Media
            ├─ <one-on-one chat>                      99G   ← this one
            ├─ <status folder>                       5.0G
            ├─ <another chat>                        3.4G
            └─ <status folder>                       3.0G
```

The message database itself is only 160 MB. Almost everything is media, and almost all
of that is in **one chat folder**.

A side note: the two status folders add up to **8 GB**. Statuses expire after 24 hours,
so keeping 8 GB of them on disk is odd. It may be the same problem or a separate one.

![du drill-down](evidence/04-du-drilldown.png)

### 7. Inside the 99 GB folder

```zsh
cd <the 99G chat folder>
find . -type f | wc -l                                          # file count
find . -type f | sed 's/.*\.//' | sort | uniq -c | sort -n | tail -5   # by extension
find . -type f -exec stat -f %z {} + | sort | uniq -c | sort -n | tail -5   # repeated sizes
```

- **102,966 files**, none larger than 200 MB, about 1 MB on average
- Subfolders go back to **2026-07-20**. If the growth started then, that's roughly
  1.4 GB a day on average over ~70 days.

Files by extension:

| Extension | Files  |
|-----------|-------:|
| `.thumb`  | 38,300 |
| `.opus`   | 27,580 |
| `.pdf`    | 15,126 |
| `.jpg`    | 12,395 |
| `.zip`    |  9,564 |

Most repeated file sizes (first measurement):

```text
 count  bytes
  7563  33254
  7563  33723
 10551   3695
 10551   3801
 10781    940
```

Tens of thousands of files, but the same handful of byte sizes over and over. The
repeated counts also come in pairs (7,563 / 7,563 and 10,551 / 10,551), which suggests
files are written together as a set. For example, 2 × 7,563 = 15,126, exactly the
number of `.pdf` files.

![size histogram](evidence/05-size-counts.png)

### 8. Second measurement, a few minutes later

```zsh
find . -type f | wc -l
find . -type f -exec stat -f %z {} + | sort -u | wc -l
find . -type f -exec stat -f %z {} + | sort | uniq -c | sort -n | tail -5
```

- **102,988 files** (+22 since the first count)
- **Only 24 unique file sizes across all 102,988 files**
- Each of the top counts went up by **exactly 1**:

```text
 before → after   bytes
  7563  →  7564   33254
  7563  →  7564   33723
 10551  → 10552    3695
 10551  → 10552    3801
 10781  → 10782     940
```

The duplication was still running during the investigation. The pattern is consistent with
each cycle writing one more copy of each attachment.

![second measurement](evidence/06-second-measurement.png)

### 9. Are the copies byte-for-byte identical?

```zsh
find . -type f -size 940c  -exec md5 -q {} + | sort | uniq -c
find . -type f -size 3801c -exec md5 -q {} + | sort | uniq -c
```

[TODO: results, e.g. "10,782 files of 940 bytes → 1 distinct MD5"]

### 10. How fast is it growing?

```zsh
find . -type f -mmin -60 | wc -l      # files written in the last 60 minutes
find . -type f | wc -l; sleep 300; find . -type f | wc -l
```

- Files written in the last 60 minutes: [TODO]
- Two counts 5 minutes apart: [TODO] → [TODO]

## Observed behavior vs. possible cause

**Observed (measured on my machine):**

- One chat's media folder: 99 GB, 102,988 files, 24 unique file sizes.
- The most common sizes repeat 7,500–10,800 times each.
- Between two measurements a few minutes apart, the file count grew and every top
  repeated size went up by exactly one.
- Files were still being written while WhatsApp was running.
- Subfolders date back to 2026-07-20, so this had been building up for weeks.

**Possible cause (hypothesis, not verified):**

I don't have access to WhatsApp's source code, so this is **not** a root-cause analysis.
The pattern fits a download or retry loop that saves an attachment to a new path but
never records it as downloaded. On the next pass (sync, relaunch or a periodic retry),
the app thinks the media is still missing and downloads it again. Other explanations
are possible, such as a sync or migration job that keeps re-importing the same messages.
Only WhatsApp can confirm the cause.

## Impact

- **Disk exhaustion:** 99 GB from one chat, on a 256 GB machine. Left alone, it keeps
  growing until the disk is full.
- **Swap pressure:** with little free space, macOS struggles to manage swap. That made
  an 8 GB machine feel much slower than its memory pressure suggested.
- **SSD wear:** every duplicate is a real write. Tens of GB of pointless writes wear
  out a non-replaceable SSD.
- **General slowness:** Spotlight, app launches and everyday use all got laggy. Nothing
  in the UI points to WhatsApp as the cause.
- **Backups:** Time Machine and other backups that include `~/Library` copy all of this too.

## Workaround

> [!WARNING]
> This deletes WhatsApp's local data on the Mac. **Any media that exists only on the
> Mac will be lost.** Save anything you need first. Your phone keeps its own copy of
> the chats.

1. **Quit WhatsApp** on the Mac (<kbd>Cmd</kbd>+<kbd>Q</kbd>, not just closing the window).
2. **Log out the Mac as a linked device.** On your phone: WhatsApp > Settings >
   Linked Devices > tap the Mac > Log out.
3. **Delete the container.** Move this folder to the Trash:
   ```text
   ~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared
   ```
   (In Finder: <kbd>Cmd</kbd>+<kbd>Shift</kbd>+<kbd>G</kbd>, paste
   `~/Library/Group Containers`, then drag the folder to the Trash and empty it.)
4. **Turn off media auto-download** in Settings > Storage and Data: on the phone now,
   and on the Mac as soon as it's linked again, before you open the affected chat.
5. **Re-link** the Mac by scanning the QR code.
6. Run `./check.sh` again after a day to make sure it isn't coming back.

**Don't use "Clear chat" or delete media from inside the Mac app** to free up space.
Deletions on a linked device may sync to your phone and other devices, and you could
lose media there too.

## Status

- **2026-09-29:** Reported to WhatsApp via in-app support.
- WhatsApp's response: [TODO]

If you're affected too, please report it to WhatsApp as well (in the app: Settings > Help)
and feel free to open an issue here with your (anonymized) `check.sh` output.

## Disclaimer

This is an independent investigation. It is not affiliated with, endorsed by, or
sponsored by WhatsApp or Meta. "WhatsApp" is a trademark of its owner. All
measurements come from my own machine and my own data. Chat identifiers, phone
numbers, usernames and paths have been removed. `check.sh` is provided as-is, under
the [MIT License](LICENSE).
