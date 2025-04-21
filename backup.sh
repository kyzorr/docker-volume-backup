#!/bin/bash
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
INI_FILE="$SCRIPT_DIR/settings.ini"
if [ ! -f "$INI_FILE" ]; then
  echo "Error: settings.ini not found!"
  exit 1
fi

source <(grep = "$INI_FILE" | sed 's/ *= */=/g')

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

send_notification() {
    local MESSAGE="$1"
    local STATUS="$2"    # "ok" or "error"
    case "$NOTIFY_SYSTEM" in
        ntfy)
            curl -s -u "$NTFY_USER:$NTFY_PASS" -d "$MESSAGE" "$NTFY_URL"
            ;;
        gotify)
            local PRIORITY="$GOTIFY_PRIORITY_OK"
            if [[ "$STATUS" == "error" ]]; then
                PRIORITY="$GOTIFY_PRIORITY_ERROR"
            fi
            curl -s \
                -F "title=Docker Backup" \
                -F "message=$MESSAGE" \
                -F "priority=${PRIORITY:-5}" \
                "$GOTIFY_URL?token=$GOTIFY_TOKEN"
            ;;
        none|*)
            # No notification
            ;;
    esac
}

backup_volumes() {
    mapfile -t VOLUMES < <(docker volume ls --format "{{.Name}}")
    SUCCESSFUL=()
    ERROR_OCCURRED=0

    for VOLUME in "${VOLUMES[@]}"; do
        if [[ ",$EXCLUDE_VOLUMES," == *",$VOLUME,"* ]]; then
            log "Skipping volume: $VOLUME"
            continue
        fi
        TIMESTAMP=$(date +%Y%m%d_%H%M%S)
        BACKUP_FILE="${BACKUP_DIR}/${VOLUME}_${TIMESTAMP}.tar.gz"
        log "Backing up $VOLUME -> $BACKUP_FILE"
        if docker run --rm -v "$VOLUME":/data -v "$BACKUP_DIR":/backup alpine \
            tar czf "/backup/${VOLUME}_${TIMESTAMP}.tar.gz" -C /data .; then
            log "Success: $VOLUME"
            SUCCESSFUL+=("$VOLUME")
        else
            log "Error: $VOLUME"
            send_notification "Backup FAILED: $VOLUME" "error"
            ERROR_OCCURRED=1
        fi
    done

    if [ "$ERROR_OCCURRED" -eq 0 ]; then
        if [[ "$NOTIFY_ON_SUCCESS" == "true" ]]; then
            VOLUME_LIST=$(printf "%s\n" "${SUCCESSFUL[@]}")
            send_notification "All backups successful: \n$VOLUME_LIST" "ok"
        fi
    fi


    dialog --msgbox "Backup of all volumes completed!" 7 40
}

backup_single_volume() {
    mapfile -t VOLUMES < <(docker volume ls --format "{{.Name}}")
    VOLUMES_MENU=()
    for i in "${!VOLUMES[@]}"; do
        VOLUMES_MENU+=($i "${VOLUMES[$i]}")
    done
    dialog --menu "Select a volume for single backup:" 15 60 8 "${VOLUMES_MENU[@]}" 2>vol_choice.tmp
    ret=$?
    if [ $ret -ne 0 ]; then rm -f vol_choice.tmp; return; fi
    VOL_IDX=$(<vol_choice.tmp)
    VOLUME="${VOLUMES[$VOL_IDX]}"
    rm -f vol_choice.tmp

    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_FILE="${BACKUP_DIR}/${VOLUME}_${TIMESTAMP}.tar.gz"
    log "Backing up $VOLUME -> $BACKUP_FILE"
    docker run --rm -v "$VOLUME":/data -v "$BACKUP_DIR":/backup alpine \
        tar czf "/backup/${VOLUME}_${TIMESTAMP}.tar.gz" -C /data . \
        && { log "Success: $VOLUME"; send_notification "Backup successful: $VOLUME" "ok"; } \
        || { log "Error: $VOLUME"; send_notification "Backup FAILED: $VOLUME" "error"; }
    dialog --msgbox "Backup for $VOLUME completed!" 7 40
}

restore_volume() {
    mapfile -t VOLUMES < <(docker volume ls --format "{{.Name}}")
    VOLUMES_MENU=()
    for i in "${!VOLUMES[@]}"; do
        VOLUMES_MENU+=($i "${VOLUMES[$i]}")
    done
    dialog --menu "Select a volume to restore:" 15 60 8 "${VOLUMES_MENU[@]}" 2>vol_choice.tmp
    ret=$?
    if [ $ret -ne 0 ]; then rm -f vol_choice.tmp; return; fi
    VOL_IDX=$(<vol_choice.tmp)
    VOLUME="${VOLUMES[$VOL_IDX]}"
    rm -f vol_choice.tmp

    mapfile -t FILES < <(ls -1 "$BACKUP_DIR/${VOLUME}_"*.tar.gz 2>/dev/null)
    if [ ${#FILES[@]} -eq 0 ]; then
        dialog --msgbox "No backups found for $VOLUME!" 7 40
        return
    fi
    FILES_MENU=()
    for i in "${!FILES[@]}"; do
        FILES_MENU+=($i "$(basename "${FILES[$i]}")")
    done
    dialog --menu "Select a backup to restore:" 20 70 10 "${FILES_MENU[@]}" 2>file_choice.tmp
    ret=$?
    if [ $ret -ne 0 ]; then rm -f file_choice.tmp; return; fi
    FILE_IDX=$(<file_choice.tmp)
    FILE="${FILES[$FILE_IDX]}"
    rm -f file_choice.tmp

    log "Restoring $FILE → $VOLUME"
    docker volume create "$VOLUME" >/dev/null 2>&1
    docker run --rm -v "$VOLUME":/data -v "$(dirname "$FILE")":/backup alpine \
        tar xzf "/backup/$(basename "$FILE")" -C /data
    dialog --msgbox "Restore for $VOLUME completed!" 7 40
}

cleanup() {
    dialog --yesno "Do you really want to delete all old backups (older than $RETENTION_DAYS days)?\n\nThis action cannot be undone!" 10 60
    response=$?
    if [ $response -eq 0 ]; then
        find "$BACKUP_DIR" -name "*.tar.gz" -type f -mtime +"$RETENTION_DAYS" -exec rm -f {} \; \
            && { log "Old backups deleted"; send_notification "Old backups deleted" "ok"; } \
            || { log "Error deleting old backups"; send_notification "Deleting old backups FAILED" "error"; }
        dialog --msgbox "Cleanup completed!" 7 40
    else
        dialog --msgbox "Cleanup cancelled." 7 40
    fi
}

setup_cron() {
    dialog --inputbox "Enter the time for automatic backup in HH:MM format (e.g., 02:00):" 8 60 "02:00" 2>cron_time.tmp
    ret=$?
    if [ $ret -ne 0 ]; then rm -f cron_time.tmp; return; fi
    CRON_TIME=$(<cron_time.tmp)
    rm -f cron_time.tmp

    dialog --menu "Choose the interval for automatic backups:" 15 60 4 \
        1 "Daily" \
        2 "Weekly" \
        3 "Monthly" 2>cron_interval.tmp
    ret=$?
    if [ $ret -ne 0 ]; then rm -f cron_interval.tmp; return; fi
    INTERVAL=$(<cron_interval.tmp)
    rm -f cron_interval.tmp

    HOUR=$(echo "$CRON_TIME" | cut -d: -f1)
    MIN=$(echo "$CRON_TIME" | cut -d: -f2)

    case "$INTERVAL" in
        1) CRON_SCHEDULE="$MIN $HOUR * * *" ;;
        2) CRON_SCHEDULE="$MIN $HOUR * * 0" ;;
        3) CRON_SCHEDULE="$MIN $HOUR 1 * *" ;;
    esac

    crontab -l | grep -v "$PWD/$(basename "$0")" > crontab.tmp 2>/dev/null
    echo "$CRON_SCHEDULE $PWD/$(basename "$0") --auto" >> crontab.tmp
    crontab crontab.tmp
    rm -f crontab.tmp

    dialog --msgbox "Automatic backup scheduled!\nCron: $CRON_SCHEDULE" 8 60
}

remove_cron() {
    crontab -l | grep -v "$PWD/$(basename "$0")" > crontab.tmp 2>/dev/null
    crontab crontab.tmp
    rm -f crontab.tmp
    dialog --msgbox "Automatic backup has been removed." 7 40
}

show_settings() {
    dialog --textbox "$INI_FILE" 20 70
}

edit_settings() {
    EDITOR_CMD="${EDITOR:-nano}"
    $EDITOR_CMD "$INI_FILE"
}

general_settings_menu() {
    while true; do
        dialog --clear --backtitle "Docker Volume Backup GUI" \
            --title "General Settings" \
            --menu "Edit general settings:" 15 60 5 \
            1 "Backup directory" \
            2 "Log file" \
            3 "Retention days" \
            4 "Exclude volumes" \
            0 "Back" 2>menu_choice.tmp

        ret=$?
        if [ $ret -ne 0 ]; then rm -f menu_choice.tmp; break; fi
        CHOICE=$(<menu_choice.tmp)
        rm -f menu_choice.tmp

        case "$CHOICE" in
            1)
                dialog --inputbox "New backup directory:" 8 60 "$BACKUP_DIR" 2>tmpval
                if [ $? -eq 0 ] && [ -s tmpval ]; then
                    sed -i "s|^BACKUP_DIR=.*|BACKUP_DIR=$(<tmpval)|" "$INI_FILE"
                fi
                rm -f tmpval
                ;;
            2)
                dialog --inputbox "New log file path:" 8 60 "$LOG_FILE" 2>tmpval
                if [ $? -eq 0 ] && [ -s tmpval ]; then
                    sed -i "s|^LOG_FILE=.*|LOG_FILE=$(<tmpval)|" "$INI_FILE"
                fi
                rm -f tmpval
                ;;
            3)
                dialog --inputbox "Retention days:" 8 60 "$RETENTION_DAYS" 2>tmpval
                if [ $? -eq 0 ] && [ -s tmpval ]; then
                    sed -i "s|^RETENTION_DAYS=.*|RETENTION_DAYS=$(<tmpval)|" "$INI_FILE"
                fi
                rm -f tmpval
                ;;
            4)
                dialog --inputbox "Exclude volumes (comma separated):" 8 60 "$EXCLUDE_VOLUMES" 2>tmpval
                if [ $? -eq 0 ] && [ -s tmpval ]; then
                    sed -i "s|^EXCLUDE_VOLUMES=.*|EXCLUDE_VOLUMES=$(<tmpval)|" "$INI_FILE"
                fi
                rm -f tmpval
                ;;
            0) break ;;
        esac
        source <(grep = "$INI_FILE" | sed 's/ *= */=/g')
    done
}

ntfy_settings_menu() {
    while true; do
        dialog --clear --backtitle "Docker Volume Backup GUI" \
            --title "ntfy Settings" \
            --menu "ntfy Settings:" 15 60 5 \
            1 "Edit ntfy URL" \
            2 "Edit ntfy User" \
            3 "Edit ntfy Password" \
            0 "Back" 2>menu_choice.tmp

        ret=$?
        if [ $ret -ne 0 ]; then rm -f menu_choice.tmp; break; fi
        CHOICE=$(<menu_choice.tmp)
        rm -f menu_choice.tmp

        case "$CHOICE" in
            1)
                dialog --inputbox "New ntfy URL:" 8 60 "$NTFY_URL" 2>tmpval
                if [ $? -eq 0 ] && [ -s tmpval ]; then
                    sed -i "s|^NTFY_URL=.*|NTFY_URL=$(<tmpval)|" "$INI_FILE"
                fi
                rm -f tmpval
                ;;
            2)
                dialog --inputbox "New ntfy User:" 8 60 "$NTFY_USER" 2>tmpval
                if [ $? -eq 0 ] && [ -s tmpval ]; then
                    sed -i "s|^NTFY_USER=.*|NTFY_USER=$(<tmpval)|" "$INI_FILE"
                fi
                rm -f tmpval
                ;;
            3)
                dialog --insecure --passwordbox "New ntfy Password:" 8 60 "$NTFY_PASS" 2>tmpval
                if [ $? -eq 0 ] && [ -s tmpval ]; then
                    sed -i "s|^NTFY_PASS=.*|NTFY_PASS=$(<tmpval)|" "$INI_FILE"
                fi
                rm -f tmpval
                ;;
            0) break ;;
        esac
        source <(grep = "$INI_FILE" | sed 's/ *= */=/g')
    done
}

gotify_settings_menu() {
    while true; do
        dialog --clear --backtitle "Docker Volume Backup GUI" \
            --title "Gotify Settings" \
            --menu "Gotify Settings:" 15 60 6 \
            1 "Edit Gotify URL" \
            2 "Edit Gotify Token" \
            3 "Edit Gotify Priority (OK)" \
            4 "Edit Gotify Priority (Error)" \
            0 "Back" 2>menu_choice.tmp

        ret=$?
        if [ $ret -ne 0 ]; then rm -f menu_choice.tmp; break; fi
        CHOICE=$(<menu_choice.tmp)
        rm -f menu_choice.tmp

        case "$CHOICE" in
            1)
                dialog --inputbox "New Gotify URL:" 8 60 "$GOTIFY_URL" 2>tmpval
                if [ $? -eq 0 ] && [ -s tmpval ]; then
                    sed -i "s|^GOTIFY_URL=.*|GOTIFY_URL=$(<tmpval)|" "$INI_FILE"
                fi
                rm -f tmpval
                ;;
            2)
                dialog --inputbox "New Gotify Token:" 8 60 "$GOTIFY_TOKEN" 2>tmpval
                if [ $? -eq 0 ] && [ -s tmpval ]; then
                    sed -i "s|^GOTIFY_TOKEN=.*|GOTIFY_TOKEN=$(<tmpval)|" "$INI_FILE"
                fi
                rm -f tmpval
                ;;
            3)
                dialog --inputbox "Gotify Priority for OK (1-10):" 8 60 "$GOTIFY_PRIORITY_OK" 2>tmpval
                if [ $? -eq 0 ] && [ -s tmpval ]; then
                    sed -i "s|^GOTIFY_PRIORITY_OK=.*|GOTIFY_PRIORITY_OK=$(<tmpval)|" "$INI_FILE"
                fi
                rm -f tmpval
                ;;
            4)
                dialog --inputbox "Gotify Priority for Error (1-10):" 8 60 "$GOTIFY_PRIORITY_ERROR" 2>tmpval
                if [ $? -eq 0 ] && [ -s tmpval ]; then
                    sed -i "s|^GOTIFY_PRIORITY_ERROR=.*|GOTIFY_PRIORITY_ERROR=$(<tmpval)|" "$INI_FILE"
                fi
                rm -f tmpval
                ;;
            0) break ;;
        esac
        source <(grep = "$INI_FILE" | sed 's/ *= */=/g')
    done
}

notification_system_menu() {
    while true; do
        dialog --clear --backtitle "Docker Volume Backup GUI" \
            --title "Notification System" \
            --menu "Select the notification system:" 12 60 4 \
            1 "None" \
            2 "ntfy" \
            3 "Gotify" \
            0 "Back" 2>menu_choice.tmp

        ret=$?
        if [ $ret -ne 0 ]; then rm -f menu_choice.tmp; break; fi
        CHOICE=$(<menu_choice.tmp)
        rm -f menu_choice.tmp

        case "$CHOICE" in
            1)
                sed -i "s|^NOTIFY_SYSTEM=.*|NOTIFY_SYSTEM=none|" "$INI_FILE"
                ;;
            2)
                sed -i "s|^NOTIFY_SYSTEM=.*|NOTIFY_SYSTEM=ntfy|" "$INI_FILE"
                ;;
            3)
                sed -i "s|^NOTIFY_SYSTEM=.*|NOTIFY_SYSTEM=gotify|" "$INI_FILE"
                ;;
            0) break ;;
        esac
        source <(grep = "$INI_FILE" | sed 's/ *= */=/g')
    done
}
notify_on_success_menu() {
    while true; do
        dialog --clear --backtitle "Docker Volume Backup GUI" \
            --title "Notify on Success" \
            --menu "Send notification if all backups are successful?" 10 60 2 \
            1 "Enable" \
            2 "Disable" \
            0 "Back" 2>menu_choice.tmp

        ret=$?
        if [ $ret -ne 0 ]; then rm -f menu_choice.tmp; break; fi
        CHOICE=$(<menu_choice.tmp)
        rm -f menu_choice.tmp

        case "$CHOICE" in
            1)
                sed -i "s|^NOTIFY_ON_SUCCESS=.*|NOTIFY_ON_SUCCESS=true|" "$INI_FILE"
                ;;
            2)
                sed -i "s|^NOTIFY_ON_SUCCESS=.*|NOTIFY_ON_SUCCESS=false|" "$INI_FILE"
                ;;
            0) break ;;
        esac
        source <(grep = "$INI_FILE" | sed 's/ *= */=/g')
    done
}


settings_menu() {
    while true; do
        dialog --clear --backtitle "Docker Volume Backup GUI" \
            --title "Settings" \
            --menu "Please select an option:" 20 60 7 \
            1 "General Settings" \
            2 "Notification System (Select)" \
            3 "ntfy Settings" \
            4 "Gotify Settings" \
            5 "Notify on Success" \
            6 "View Settings" \
            0 "Back" 2>menu_choice.tmp

        ret=$?
        if [ $ret -ne 0 ]; then rm -f menu_choice.tmp; break; fi
        CHOICE=$(<menu_choice.tmp)
        rm -f menu_choice.tmp

        case "$CHOICE" in
            1) general_settings_menu ;;
            2) notification_system_menu ;;
            3) ntfy_settings_menu ;;
            4) gotify_settings_menu ;;
            5) notify_on_success_menu ;;
            6) show_settings ;;
            0) break ;;
        esac
    done
}


backup_menu() {
    while true; do
        dialog --clear --backtitle "Docker Volume Backup GUI" \
            --title "Backup" \
            --menu "Please select an action:" 15 60 4 \
            1 "Backup all volumes" \
            2 "Backup a single volume" \
            3 "Restore a volume" \
            0 "Back" 2>menu_choice.tmp

        ret=$?
        if [ $ret -ne 0 ]; then rm -f menu_choice.tmp; break; fi
        CHOICE=$(<menu_choice.tmp)
        rm -f menu_choice.tmp

        case "$CHOICE" in
            1) backup_volumes ;;
            2) backup_single_volume ;;
            3) restore_volume ;;
            0) break ;;
        esac
    done
}

options_menu() {
    while true; do
        dialog --clear --backtitle "Docker Volume Backup GUI" \
            --title "Options" \
            --menu "Please select an option:" 15 60 4 \
            1 "Delete old backups" \
            2 "Schedule automatic backups" \
            3 "Remove automatic backups" \
            0 "Back" 2>menu_choice.tmp

        ret=$?
        if [ $ret -ne 0 ]; then rm -f menu_choice.tmp; break; fi
        CHOICE=$(<menu_choice.tmp)
        rm -f menu_choice.tmp

        case "$CHOICE" in
            1) cleanup ;;
            2) setup_cron ;;
            3) remove_cron ;;
            0) break ;;
        esac
    done
}

main_menu() {
    while true; do
        dialog --clear --backtitle "Docker Volume Backup GUI" \
            --title "Main Menu" \
            --menu "Please select a category:" 17 70 5 \
            1 "Backup" \
            2 "Options" \
            3 "Settings" \
            0 "Exit" 2>menu_choice.tmp

        ret=$?
        if [ $ret -ne 0 ]; then rm -f menu_choice.tmp; clear; exit 0; fi
        CHOICE=$(<menu_choice.tmp)
        rm -f menu_choice.tmp

        case "$CHOICE" in
            1) backup_menu ;;
            2) options_menu ;;
            3) settings_menu ;;
            0) clear; exit 0 ;;
        esac
    done
}

# For cron: --auto option
if [[ "$1" == "--auto" ]]; then
    backup_volumes
    cleanup
    exit 0
fi

main_menu
clear
