# Nextcloud
- Uses Nextcloud AIO suites of Docker 

## Obsidian Mobile Syncing
- Nextcloud doesn't play nice with Obsidian on Android (files created in phone doesn't sync)
- Instead, use Remotely Save plugin: WebDAV with App Password (token)

## Storage
- Does not use ZFS due to spindown, causing the following issues:
  - Nextcloud mobile can't access files sometimes
  - Unreliable and slow Obsidian launch
- Borg backup uses ZFS