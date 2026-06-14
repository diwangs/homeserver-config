# Nextcloud
- Uses Nextcloud AIO suites of Docker 

## Obsidian Mobile Syncing
- Nextcloud doesn't play nice with Obsidian on Android (files created in phone doesn't sync)
- Instead, use WebDAV with App Password (token)

## Storage
- Uses the LVM storage for now
  - Does not use ZFS directly, because of timeout issue due to spindown
  - Does not use the bigger LVM-Thin, because there's no backup mechanism yet
  - Plan to migrate to LVM-Thin after Borg backup mechanism is set up