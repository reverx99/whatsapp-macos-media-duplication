# Evidence

Screenshots referenced from the main [README](../README.md). Every image is cropped
and redacted before it's added here: no chat or group IDs (`...@lid`, `...@g.us`,
`...@s.whatsapp.net`), phone numbers, contact names, macOS username, hostname or
`/Users/<name>` paths.

| File                       | Shows                                                      |
|----------------------------|------------------------------------------------------------|
| `01-htop.png`              | Load average, swap 3.24 G / 4 G, 14 days uptime            |
| `02-activity-monitor.png`  | Memory tab: pressure green, 6.37 GB used, 3.18 GB swap     |
| `03-df.png`                | `df -h /System/Volumes/Data`: 93% full, 13 Gi available    |
| `04-du-drilldown.png`      | `du` from `~/Library` down to the 99 G chat folder         |
| `05-size-counts.png`       | Most repeated file sizes, first measurement                |
| `06-second-measurement.png`| 102,988 files, 24 unique sizes, each top count +1          |

## Redaction checklist

- [ ] Terminal prompt doesn't show the username or hostname
- [ ] No folder names from `Message/Media/` are visible
- [ ] No contact names, profile pictures or message content
- [ ] Image metadata stripped (e.g. `exiftool -all= file.png`, or re-export the screenshot)
