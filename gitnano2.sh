#!/bin/bash
# =================================================================
# Unified GitNano & Puppet Master SSH Provisioner
# =================================================================

# 1. PARAMETERS
NEW_FQDN="${1:-your-offline-gitnano-fqdn}"
GITNANO_USER="gitnano"
INSTALL_DIR="/opt/gitnano"
PUPPET_USER="pe-puppet" 
PUPPET_SSH_DIR="/etc/puppetlabs/puppetserver/ssh"
PRIVATE_KEY="$PUPPET_SSH_DIR/id-control_repo.rsa"
REPO_PATH="$INSTALL_DIR/repos/control-repo.git"

echo "🎯 Starting Unified Provisioning for $NEW_FQDN..."

# 2. SSHD CONFIG REPAIR (Prevents the 30-second hang)
echo "🔧 Optimizing SSHD for local loopback..."
sed -i 's/^#UseDNS yes/UseDNS no/' /etc/ssh/sshd_config
sed -i 's/^UseDNS yes/UseDNS no/' /etc/ssh/sshd_config
grep -q "^UseDNS no" /etc/ssh/sshd_config || echo "UseDNS no" >> /etc/ssh/sshd_config
systemctl restart ssh

# 3. PREPARE GITNANO USER (Ensure valid shell)
echo "👤 Fixing gitnano user shell..."
usermod -s /bin/bash $GITNANO_USER
passwd -u $GITNANO_USER 2>/dev/null

# 4. PREPARE PUPPET SSH KEYS
echo "🔑 Configuring Puppet service keys..."
mkdir -p "$PUPPET_SSH_DIR"
if [ ! -f "$PRIVATE_KEY" ]; then
    ssh-keygen -t rsa -b 4096 -f "$PRIVATE_KEY" -N "" -q
fi
chown -R $PUPPET_USER:$PUPPET_USER "$PUPPET_SSH_DIR"
chmod 700 "$PUPPET_SSH_DIR"
chmod 600 "$PRIVATE_KEY"

# 5. AUTHORIZED_KEYS SYNC
echo "👤 Syncing authorized_keys..."
mkdir -p "$INSTALL_DIR/.ssh"
cat "${PRIVATE_KEY}.pub" > "$INSTALL_DIR/.ssh/authorized_keys"
chown -R $GITNANO_USER:$GITNANO_USER "$INSTALL_DIR/.ssh"
chmod 700 "$INSTALL_DIR/.ssh"
chmod 600 "$INSTALL_DIR/.ssh/authorized_keys"

# 6. SEED FQDN TRUST
echo "🛡  Seeding FQDN trust..."
ssh-keygen -f /etc/ssh/ssh_known_hosts -R "$NEW_FQDN" 2>/dev/null
ssh-keyscan -t rsa,ed25519 "$NEW_FQDN" >> /etc/ssh/ssh_known_hosts 2>/dev/null

# 7. FINAL CONNECTION TEST (Non-Hanging Version)
echo "🧪 Testing handshake..."

# Use 'env -i' to ensure a clean path for the test
TEST_CMD="sudo -u $PUPPET_USER ssh -o BatchMode=yes -o GSSAPIAuthentication=no -o ConnectTimeout=5 -i $PRIVATE_KEY $GITNANO_USER@$NEW_FQDN 'printf \"SSH_LOGIN_WORKS\n\"; git-upload-pack --version'"

echo "Running test..."
RESULT=$(eval "$TEST_CMD" 2>&1)

if [[ $RESULT == *"git version"* ]] || [[ $RESULT == *"SSH_LOGIN_WORKS"* ]]; then
    echo "------------------------------------------------"
    echo "✅ SUCCESS: Puppet and GitNano are fully linked!"
    echo "------------------------------------------------"
    echo "📍 r10k Remote: $GITNANO_USER@$NEW_FQDN:$REPO_PATH"
else
    echo "❌ ERROR: Connection established but Git command failed."
    echo "Result: $RESULT"
fi
