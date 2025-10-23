#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Single-file installer with embedded repo content
# Save as /root/combined-inline-repo.sh and run as root.

NEW_HOSTNAME="machine1.exam.com"
MAN_REPO="https://github.com/codexchangee/rhel-manpages.git"
TMP_DIR="/tmp/rhel-manpages"
DVD_MOUNT="/dvd"
REPO_DIR="/etc/yum.repos.d"
CREATED_REPOS=()
HTTP_CONF="/etc/httpd/conf/httpd.conf"
HTTP_CONF_BAK="/etc/httpd/conf/httpd.conf.bak"

# Embedded repo content (this lives inside the same script)
# Replace these baseurls if you want different mirrors.
read -r -d '' EMBEDDED_REPO <<'REPO_EOF' || true
[AppStream]
name=Embedded AppStream
baseurl = http://ftp.scientificlinux.org/linux/redhat/rhel/rhel-9-beta/appstream/x86_64/
enabled = 1
gpgcheck = 0

[BaseOS]
name=Embedded BaseOS
baseurl = http://ftp.scientificlinux.org/linux/redhat/rhel/rhel-9-beta/baseos/x86_64/
enabled = 1
gpgcheck = 0
REPO_EOF

# Choose package manager (dnf preferred)
if command -v dnf >/dev/null 2>&1; then
    PKGMGR="dnf"
else
    PKGMGR="yum"
fi

echo "=== Combined single-file installer starting ==="

### 1) Hostname
CURRENT_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
if [ "$CURRENT_HOSTNAME" != "$NEW_HOSTNAME" ]; then
    echo "Setting hostname: $CURRENT_HOSTNAME -> $NEW_HOSTNAME"
    hostnamectl set-hostname "$NEW_HOSTNAME"
    if grep -q "$CURRENT_HOSTNAME" /etc/hosts 2>/dev/null; then
        sed -i "s/$CURRENT_HOSTNAME/$NEW_HOSTNAME/g" /etc/hosts || true
    else
        grep -q "127.0.0.1" /etc/hosts || echo "127.0.0.1   localhost" >> /etc/hosts
        echo "127.0.0.1   $NEW_HOSTNAME" >> /etc/hosts
    fi
else
    echo "Hostname already $NEW_HOSTNAME"
fi

### 2) Detect optical device (sr1 preferred then sr0) and mount if present
ISO_DEV=""
if [ -b /dev/sr1 ]; then
    ISO_DEV="/dev/sr1"
elif [ -b /dev/sr0 ]; then
    ISO_DEV="/dev/sr0"
fi

if [ -n "$ISO_DEV" ]; then
    echo "Found optical device: $ISO_DEV"
    mkdir -p "$DVD_MOUNT"
    if ! mountpoint -q "$DVD_MOUNT"; then
        if mount -o ro "$ISO_DEV" "$DVD_MOUNT"; then
            echo "Mounted $ISO_DEV -> $DVD_MOUNT"
        else
            echo "Mount failed for $ISO_DEV; ignoring and falling back to embedded repo."
            ISO_DEV=""
        fi
    else
        echo "$DVD_MOUNT already mounted"
    fi
else
    echo "No optical device found (sr1/sr0)."
fi

### 3) Create repo: prefer DVD local repo; else create embedded (inline) repo file
CREATE_LOCAL_REPO=false
if [ -n "$ISO_DEV" ] && [ -d "$DVD_MOUNT" ]; then
    # Simple check for RHEL-style layout
    if [ -d "$DVD_MOUNT"/BaseOS ] || [ -d "$DVD_MOUNT"/AppStream ] || [ -f "$DVD_MOUNT"/.treeinfo ]; then
        CREATE_LOCAL_REPO=true
    else
        echo "Mounted media doesn't appear to be RHEL DVD media."
    fi
fi

if $CREATE_LOCAL_REPO; then
    LOCAL_REPO_FILE="$REPO_DIR/local-dvd.repo"
    echo "Creating local DVD repo file: $LOCAL_REPO_FILE"
    cat > "$LOCAL_REPO_FILE" <<EOF
[BaseOS]
name=Local DVD BaseOS
baseurl=file://$DVD_MOUNT/BaseOS
enabled=1
gpgcheck=0

[AppStream]
name=Local DVD AppStream
baseurl=file://$DVD_MOUNT/AppStream
enabled=1
gpgcheck=0
EOF
    CREATED_REPOS+=("$LOCAL_REPO_FILE")
    # persist mount in fstab (avoid duplicates)
    FSTAB_LINE="$ISO_DEV $DVD_MOUNT iso9660 loop,ro 0 0"
    if ! grep -Fq "$FSTAB_LINE" /etc/fstab 2>/dev/null; then
        echo "$FSTAB_LINE" >> /etc/fstab
    fi
    echo "Local DVD repo created."
else
    # No DVD -> create repo file from the embedded repo content in this script
    EMBED_REPO_FILE="$REPO_DIR/embedded-inline.repo"
    echo "No DVD detected. Creating embedded repo file: $EMBED_REPO_FILE"
    cat > "$EMBED_REPO_FILE" <<EOF
$EMBEDDED_REPO
EOF
    CREATED_REPOS+=("$EMBED_REPO_FILE")
    echo "Embedded repo created at $EMBED_REPO_FILE (points to remote mirrors)."
    # Attempt to refresh cache (may fail if no internet)
    echo "Refreshing package metadata (best-effort)..."
    $PKGMGR makecache --refresh -y || echo "makecache failed or no internet — continuing."
fi

### 4) Remove bzip2 if present (as original)
if rpm -q bzip2 >/dev/null 2>&1; then
    echo "Removing bzip2..."
    $PKGMGR remove -y bzip2 || true
fi

### 5) Install httpd and ensure it is enabled
echo "Installing httpd..."
$PKGMGR install -y httpd || echo "httpd install failed (no repo/internet?) — continuing."

echo "Starting/enabling httpd..."
systemctl enable --now httpd || echo "Could not enable/start httpd."

### 6) Change Listen 80 -> 82 safely (backup + rollback if restart fails)
if [ -f "$HTTP_CONF" ]; then
    echo "Backing up $HTTP_CONF to $HTTP_CONF_BAK"
    cp -p "$HTTP_CONF" "$HTTP_CONF_BAK"
    echo "Updating Listen 80 -> 82 in /etc/httpd"
    # safe replacements
    grep -rl --exclude-dir=conf.modules.d "Listen 80" /etc/httpd 2>/dev/null | xargs -r sed -i 's/Listen 80/Listen 82/g' || true
    if systemctl restart httpd; then
        echo "httpd restarted successfully after port change."
    else
        echo "httpd failed to restart. Restoring backup and retrying."
        cp -p "$HTTP_CONF_BAK" "$HTTP_CONF" || true
        systemctl restart httpd || true
    fi
else
    echo "$HTTP_CONF not found; skipping Listen change."
fi

### 7) Create web files and set SELinux type for file1 (best-effort)
mkdir -p /var/www/html
touch /var/www/html/file1 /var/www/html/file2 /var/www/html/file3
chcon -t user_home_t /var/www/html/file1 || true

### 8) Create users and set password to 'root' (as requested)
for username in simone remoteuserx andrew siya test1 test2 user1 user2 pandora alex; do
    if ! id "$username" >/dev/null 2>&1; then
        useradd "$username" || true
    fi
    echo "$username:root" | chpasswd || true
done
echo "Users created/updated."

### 9) Install GUI group only if available from repos
echo "Checking Server with GUI availability..."
if $PKGMGR groupinfo "Server with GUI" >/dev/null 2>&1; then
    echo "Installing Server with GUI..."
    $PKGMGR groupinstall -y "Server with GUI" || echo "Server with GUI groupinstall failed."
else
    echo "Server with GUI group not available; skipping GUI installation."
fi

### 10) Ensure git installed and handle manpage repo if accessible
$PKGMGR install -y git || true
echo "Checking manpage repo accessibility..."
if git ls-remote "$MAN_REPO" >/dev/null 2>&1; then
    echo "Cloning manpage repository..."
    rm -rf "$TMP_DIR"
    git clone --depth 1 "$MAN_REPO" "$TMP_DIR" || true
    if [ -d "$TMP_DIR/man1" ]; then
        mkdir -p /usr/share/man/man1
        cp -f "$TMP_DIR"/man1/*.1 /usr/share/man/man1/ 2>/dev/null || true
        command -v mandb >/dev/null 2>&1 && mandb || true
    else
        echo "No man1 directory in the repo; skipping man page copy."
    fi

    # create /usr/sbin/ex200
    cat >/usr/sbin/ex200 <<'EOF'
#!/bin/bash
if [ -f ~/.ex200/ex200.conf ]; then
    cat ~/.ex200/ex200.conf
else
    echo "There Is No Message For You Dude"
fi
EOF
    chmod +x /usr/sbin/ex200 || true

    # create /usr/sbin/welcome_message
    cat >/usr/sbin/welcome_message <<'EOF'
#!/bin/bash
CURRENT_USER=$(whoami)
if [ "$CURRENT_USER" == "pandora" ]; then
    echo "$USER_MESSAGE"
else
    echo "No message specified"
fi
EOF
    chmod +x /usr/sbin/welcome_message || true
else
    echo "Manpage repo not accessible; skipping clone and related script creation."
fi

### 11) Final cleanup: delete only repo files this script created, then clear history and reboot
echo "Final cleanup: removing repo files created by this script (if any)."
if [ ${#CREATED_REPOS[@]} -ne 0 ]; then
    for rf in "${CREATED_REPOS[@]}"; do
        if [ -f "$rf" ]; then
            echo " - Deleting $rf"
            rm -f "$rf" || true
        fi
    done
    $PKGMGR clean all || true
else
    echo "No repo files were created by the script."
fi

echo "Clearing shell history..."
history -c || true

# Self-delete (best-effort) and reboot
SELF="$0"
if [ -f "$SELF" ]; then
    echo "Removing installer script $SELF"
    rm -f -- "$SELF" || true
fi

echo "Rebooting now..."
sleep 1
reboot
