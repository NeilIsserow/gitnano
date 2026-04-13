#!/bin/bash
# =================================================================
# GitNano: Unified Single-Node Installation (Git + Puppet Auth)
# =================================================================

# --- 1. CONFIGURATION (Edit as needed) ---
OLD_GITLAB_URL="${1:-http://gitlab.c.tampuppettestenv.internal/puppet/control-repo.git}"
NEW_FQDN="${2:-neilgitcore0.c.tampuppettestenv.internal}"
TOKEN="${3:-your-secure-puppet-token}"

GITNANO_USER="gitnano"
INSTALL_DIR="/opt/gitnano"
REPO_NAME="control-repo.git"
LIVE_DIR="/var/www/production"

PUPPET_USER="pe-puppet"
PUPPET_SSH_DIR="/etc/puppetlabs/puppetserver/ssh"
PRIVATE_KEY="$PUPPET_SSH_DIR/id-control_repo.rsa"

export DEBIAN_FRONTEND=noninteractive

echo "🚀 Starting Unified GitNano Deployment for $NEW_FQDN..."

# --- 2. SYSTEM PREP & USERS ---
apt-get update -q -y
apt-get install -y python3 python3-venv git curl openssh-server net-tools

if ! id -u $GITNANO_USER &>/dev/null; then
    useradd -r -m -d $INSTALL_DIR -s /bin/bash $GITNANO_USER
fi
# Ensure user is unlocked and has a shell
usermod -s /bin/bash $GITNANO_USER
passwd -u $GITNANO_USER 2>/dev/null

# Fix /opt permissions (Critical for SSH)
chown root:root /opt
chmod 755 /opt

mkdir -p $INSTALL_DIR/app $INSTALL_DIR/repos $LIVE_DIR
chown -R $GITNANO_USER:$GITNANO_USER $INSTALL_DIR $LIVE_DIR

# --- 3. GLOBAL GIT FIXES (Ownership & Identity) ---
for user in "root" "$GITNANO_USER"; do
    CMD_PREFIX=""
    [ "$user" != "root" ] && CMD_PREFIX="sudo -u $user"
    $CMD_PREFIX git config --global --add safe.directory "$INSTALL_DIR/repos/$REPO_NAME"
    $CMD_PREFIX git config --global --add safe.directory "$LIVE_DIR"
    $CMD_PREFIX git config --global user.email "gitnano@$NEW_FQDN"
    $CMD_PREFIX git config --global user.name "GitNano Automator"
done

# --- 4. PYTHON API BRIDGE SETUP ---
sudo -u $GITNANO_USER python3 -m venv $INSTALL_DIR/app/venv
sudo -u $GITNANO_USER $INSTALL_DIR/app/venv/bin/pip install --quiet flask gunicorn

cat <<EOF > $INSTALL_DIR/app/gitnano.py
import os, subprocess
from flask import Flask, request, Response, abort
app = Flask(__name__)
REPO_ROOT = "$INSTALL_DIR/repos"
AUTH_TOKEN = "$TOKEN"
def check_auth():
    if request.headers.get('Authorization') != f"Bearer {AUTH_TOKEN}": abort(401)
@app.route('/<repo_name>/info/refs', methods=['GET'])
def info_refs(repo_name):
    check_auth()
    service = request.args.get('service')
    repo_path = os.path.join(REPO_ROOT, repo_name)
    rpc_content = f"# service={service}\n"
    header = f"{len(rpc_content) + 4:04x}{rpc_content}0000"
    proc = subprocess.Popen(['git', service.replace('git-', ''), "--stateless-rpc", "--advertise-refs", repo_path], stdout=subprocess.PIPE)
    return Response(header.encode() + proc.communicate()[0], content_type=f"application/x-{service}-advertisement")
@app.route('/<repo_name>/<service>', methods=['POST'])
def service_rpc(repo_name, service):
    check_auth()
    repo_path = os.path.join(REPO_ROOT, repo_name)
    proc = subprocess.Popen(['git', service.replace('git-', ''), "--stateless-rpc", repo_path], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    return Response(proc.communicate(input=request.data)[0], content_type=f"application/x-{service}-result")
if __name__ == '__main__': app.run(host='0.0.0.0', port=5000)
EOF

# --- 5. SYSTEMD SERVICE ---
cat <<EOF > /etc/systemd/system/gitnano.service
[Unit]
Description=GitNano Service
After=network.target
[Service]
User=$GITNANO_USER
Group=$GITNANO_USER
WorkingDirectory=$INSTALL_DIR/app
ExecStart=$INSTALL_DIR/app/venv/bin/gunicorn --workers 1 --bind 0.0.0.0:5000 gitnano:app
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now gitnano

# --- 6. SSHD OPTIMIZATION (No-Hang Fix) ---
echo "🔧 Optimizing SSH Daemon..."
sed -i 's/^#UseDNS yes/UseDNS no/' /etc/ssh/sshd_config
sed -i 's/^UseDNS yes/UseDNS no/' /etc/ssh/sshd_config
sed -i 's/^GSSAPIAuthentication yes/GSSAPIAuthentication no/' /etc/ssh/sshd_config
systemctl restart ssh

# --- 7. DATA MIGRATION ---
echo "🚚 Migrating data from $OLD_GITLAB_URL..."
rm -rf "$INSTALL_DIR/repos/$REPO_NAME"
sudo -u $GITNANO_USER git init --bare "$INSTALL_DIR/repos/$REPO_NAME"
sudo -u $GITNANO_USER git -C "$INSTALL_DIR/repos/$REPO_NAME" symbolic-ref HEAD refs/heads/production

MIGRATE_DIR=$(mktemp -d)
chown $GITNANO_USER "$MIGRATE_DIR"
sudo -u $GITNANO_USER git clone --mirror "$OLD_GITLAB_URL" "$MIGRATE_DIR"
if [ $? -eq 0 ]; then
    cd "$MIGRATE_DIR"
    sudo -u $GITNANO_USER git push --mirror "$INSTALL_DIR/repos/$REPO_NAME"
fi
rm -rf "$MIGRATE_DIR"

# --- 8. SETUP LIVE DIRECTORY & TOKEN AUTH ---
echo "📂 Setting up production working copy..."

# Jump out of any directory that might be deleted
cd /tmp

# Clean start for the live directory
rm -rf "$LIVE_DIR"
mkdir -p "$LIVE_DIR"
chown $GITNANO_USER:$GITNANO_USER $LIVE_DIR

# Perform the clone
echo "📥 Cloning to $LIVE_DIR..."
sudo -u $GITNANO_USER git clone --branch production "$INSTALL_DIR/repos/$REPO_NAME" "$LIVE_DIR"

# Move INTO the new directory before running git configs
cd "$LIVE_DIR" || exit 1

# Setup the API bridge for internal pushes
echo "⚙  Configuring GitNano API bridge..."
sudo -u $GITNANO_USER git remote add gitnano "http://:@localhost:5000/$REPO_NAME"
sudo -u $GITNANO_USER git config http.extraHeader "Authorization: Bearer $TOKEN"

# Mark it safe one more time specifically at this path
sudo -u $GITNANO_USER git config --global --add safe.directory "$LIVE_DIR"

# --- 9. PUPPET MASTER SSH LINKING (The Final Step) ---
echo "🔗 Finalizing SSH link..."
mkdir -p "$PUPPET_SSH_DIR" "$INSTALL_DIR/.ssh"

# Key Generation/Sync
if [ ! -f "$PRIVATE_KEY" ]; then
    ssh-keygen -t rsa -b 4096 -f "$PRIVATE_KEY" -N "" -q
fi
ssh-keygen -y -f "$PRIVATE_KEY" > "$INSTALL_DIR/.ssh/authorized_keys"

# Set strict permissions
chown -R $PUPPET_USER:$PUPPET_USER "$PUPPET_SSH_DIR"
chmod 700 "$PUPPET_SSH_DIR"
chmod 600 "$PRIVATE_KEY"

chown -R $GITNANO_USER:$GITNANO_USER "$INSTALL_DIR/.ssh"
chmod 700 "$INSTALL_DIR/.ssh"
chmod 600 "$INSTALL_DIR/.ssh/authorized_keys"

# Seed Known Hosts
ssh-keyscan -t rsa,ed25519 "$NEW_FQDN" localhost 127.0.0.1 >> /etc/ssh/ssh_known_hosts 2>/dev/null

# --- 10. VERIFICATION ---
echo "🧪 Testing Puppet-to-GitNano handshake..."
TEST_CMD="sudo -u $PUPPET_USER ssh -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -i $PRIVATE_KEY $GITNANO_USER@$NEW_FQDN 'git --version'"

RESULT=$(eval "$TEST_CMD" 2>&1)

if [[ $RESULT == *"git version"* ]]; then
    echo "------------------------------------------------"
    echo "✅ INSTALLATION COMPLETE & VERIFIED!"
    echo "📍 Git URL: $GITNANO_USER@$NEW_FQDN:$INSTALL_DIR/repos/$REPO_NAME"
    echo "📍 Live Dir: $LIVE_DIR"
    echo "------------------------------------------------"
else
    echo "------------------------------------------------"
    echo "⚠  Install done, but Handshake test failed."
    echo "Error: $RESULT"
    echo "------------------------------------------------"
fi
