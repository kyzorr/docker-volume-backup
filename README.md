# Docker Volume Backup Script

This Bash script provides an interactive TUI (dialog-based) interface for backing up and restoring Docker volumes, with support for scheduled backups and notifications via **Gotify** or **ntfy**.

---

## Features

- Backup all or selected Docker volumes
- Restore volumes from backups
- Automatic cleanup of old backups
- Schedule automatic backups via cron
- Interactive settings management (no manual file editing needed)
- Notification support: choose between **Gotify**, **ntfy**, or no notifications
- Adjustable notification priority for Gotify (e.g., high for errors, low for success)

---

## Requirements

- Bash
- `dialog` package (for TUI)
- Docker
- `curl`

---

## Installation

1. **Download the script** and place it in your desired directory, e.g. `/opt/docker-backups/backup.sh`
2. **Make it executable:**

```bash
chmod +x /opt/docker-backups/backup.sh
```

3. **Create a `settings.ini` file** in the same directory.
See below for an example.

---

## Example `settings.ini`

```ini
BACKUP_DIR=/opt/docker-backups
LOG_FILE=/opt/docker-backups/backup.log
RETENTION_DAYS=7
EXCLUDE_VOLUMES=

NOTIFY_SYSTEM=gotify          # Options: none, ntfy, gotify

# ntfy settings
NTFY_URL=https://ntfy.example.com/your-topic
NTFY_USER=youruser
NTFY_PASS=yourpassword

# gotify settings
GOTIFY_URL=https://gotify.example.com/message
GOTIFY_TOKEN=your_app_token
GOTIFY_PRIORITY_OK=3
GOTIFY_PRIORITY_ERROR=9
```

---

## Usage

Run the script:

```bash
./backup.sh
```

You will see a dialog-based menu with options for backup, restore, options, and settings.

### Main Menu

- **Backup:** Backup all or a single volume, or restore a volume.
- **Options:** Delete old backups, schedule or remove automatic backups.
- **Settings:** Configure general settings, notification system, and notification service parameters.

---

## Notifications

### Choose Your Notification System

- Go to **Settings > Notification System (Select)** and choose:
    - **none:** No notifications will be sent
    - **ntfy:** Use ntfy for notifications
    - **gotify:** Use Gotify for notifications


### Configure ntfy

- Fill in `NTFY_URL`, `NTFY_USER`, and `NTFY_PASS` in your `settings.ini`.
- Example:

```
NTFY_URL=https://ntfy.example.com/your-topic
NTFY_USER=myuser
NTFY_PASS=mypassword
```


### Configure Gotify

1. **Set up your Gotify server** and create an app to get your token.
2. Fill in `GOTIFY_URL` and `GOTIFY_TOKEN` in your `settings.ini`.
3. Optionally, set notification priorities for OK and error events:

```
GOTIFY_PRIORITY_OK=3
GOTIFY_PRIORITY_ERROR=9
```


---

## Testing Notifications

**Test Gotify from the command line:**

```bash
curl -L "https://your-gotify.example.com/message?token=your_app_token" \
  -F "title=Test" \
  -F "message=This is a test message" \
  -F "priority=5"
```

**Test ntfy from the command line:**

```bash
curl -u youruser:yourpassword -d "This is a test message" https://ntfy.example.com/your-topic
```

If you see the message in the web interface or app, notifications are working.

---

## Troubleshooting

- Make sure your `settings.ini` contains **no spaces around `=`** and **no quotes** around values.
- If notifications work via `curl` but not via the script:
    - Ensure `NOTIFY_SYSTEM` is set correctly.
    - Check the script’s debug output (enable debug lines in the `send_notification` function).
    - Make sure the script is using the correct `settings.ini` (same directory).
    - If running via cron, check that the environment and permissions are correct.
- For Gotify, always use the **full HTTPS URL** (not HTTP if redirected).
- Check your Gotify or ntfy server logs if you receive no messages.

---

## Scheduling Backups

- Use the script's **Options > Schedule automatic backups** menu to set up a cron job for automated backups.

---

## Security

- Keep your notification tokens and credentials secure.
- Restrict access to the script and `settings.ini` file.

---

## License

This script is provided as-is, with no warranty.
Feel free to modify and adapt it to your needs!

---

**Enjoy safe and automated Docker volume backups with notification support!**
If you have questions or need help, just ask.

