# =================================================================
# Class: profile::gitnano
# Description: Deploys the GitNano Smart HTTP API and configures
#              the secure loopback SSH handshake for Puppet Master.
#              Bypasses environment class-signature validation bugs.
# =================================================================
class profile::gitnano {

  # 0. Pure Hiera Data Bindings
  $old_gitlab_url = lookup('profile::gitnano::old_gitlab_url')
  $api_token      = lookup('profile::gitnano::api_token')
  $new_fqdn       = lookup('profile::gitnano::new_fqdn')

  $gitnano_user    = 'gitnano'
  $install_dir     = '/opt/gitnano'
  $repo_name       = 'control-repo.git'
  $live_dir        = '/var/www/production'
  $puppet_user     = 'pe-puppet'
  $puppet_ssh_dir  = '/etc/puppetlabs/puppetserver/ssh'
  $private_key     = "${puppet_ssh_dir}/id-control_repo.rsa"

  # 1. Install Base Packages
  package { ['python3', 'python3-venv', 'git', 'curl', 'openssh-server', 'net-tools']:
    ensure => present,
  }

  # 2. System User Configuration
  user { $gitnano_user:
    ensure     => present,
    home       => $install_dir,
    shell      => '/bin/bash',
    managehome => false,
  }

  exec { 'unlock_gitnano_user':
    command => "passwd -u ${gitnano_user}",
    path    => ['/usr/bin', '/usr/sbin', '/bin'],
    onlyif  => "passwd -S ${gitnano_user} | grep -q 'L'",
    require => User[$gitnano_user],
  }

  # 3. Secure Directory Perms (Crucial Parent SSH enforcement)
  file { '/opt':
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
  }

  file { [ $install_dir, "${install_dir}/app", "${install_dir}/repos", $live_dir ]:
    ensure  => directory,
    owner   => $gitnano_user,
    group   => $gitnano_user,
    mode    => '0755',
    require => [User[$gitnano_user], File['/opt']],
  }

  file { "${install_dir}/.ssh":
    ensure => directory,
    owner  => $gitnano_user,
    group  => $gitnano_user,
    mode   => '0700',
  }

  # 4. Global Git Safe Directory Settings
  ['root', $gitnano_user].each |$user| {
    exec { "git_safe_repo_${user}":
      command => "git config --global --add safe.directory ${install_dir}/repos/${repo_name}",
      path    => ['/usr/bin', '/bin'],
      user    => $user,
      unless  => "git config --global --get-all safe.directory | grep -q '^${install_dir}/repos/${repo_name}$'",
    }
    exec { "git_safe_live_${user}":
      command => "git config --global --add safe.directory ${live_dir}",
      path    => ['/usr/bin', '/bin'],
      user    => $user,
      unless  => "git config --global --get-all safe.directory | grep -q '^${live_dir}$'",
    }
  }

  # 5. Python API Virtual Environment & Script
  exec { 'create_gitnano_venv':
    command => "python3 -m venv ${install_dir}/app/venv",
    path    => ['/usr/bin', '/bin'],
    user    => $gitnano_user,
    creates => "${install_dir}/app/venv",
    require => File["${install_dir}/app"],
  }

  exec { 'install_gitnano_pip_deps':
    command => "${install_dir}/app/venv/bin/pip install flask gunicorn",
    path    => ['/usr/bin', '/bin'],
    user    => $gitnano_user,
    unless  => "${install_dir}/app/venv/bin/pip show flask gunicorn",
    require => Exec['create_gitnano_venv'],
  }

  file { "${install_dir}/app/gitnano.py":
    ensure  => file,
    owner   => $gitnano_user,
    group   => $gitnano_user,
    mode    => '0600',
    content => @("EOF"),
import os, subprocess
from flask import Flask, request, Response, abort
app = Flask(__name__)
REPO_ROOT = "${install_dir}/repos"
AUTH_TOKEN = "${api_token}"
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
| EOF
    notify  => Service['gitnano'],
  }

  # 6. Service Management (Hardened state detection)
  file { '/etc/systemd/system/gitnano.service':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => @("EOF"),
[Unit]
Description=GitNano Smart HTTP API Bridge
After=network.target

[Service]
User=${gitnano_user}
Group=${gitnano_user}
WorkingDirectory=${install_dir}/app
ExecStart=${install_dir}/app/venv/bin/gunicorn --workers 1 --bind 0.0.0.0:5000 gitnano:app
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
| EOF
    notify  => Exec['gitnano-systemd-reload'],
  }

  exec { 'gitnano-systemd-reload':
    command     => 'systemctl daemon-reload',
    path        => ['/usr/bin', '/bin', '/usr/sbin', '/sbin'],
    refreshonly => true,
  }

  # Hardened Overrides: Forces absolute systemd status compliance if manually stopped
  service { 'gitnano':
    ensure     => 'running',
    enable     => true,
    provider   => 'systemd',
    hasstatus  => false,
    hasrestart => true,
    status     => 'systemctl is-active gitnano',
    start      => 'systemctl start gitnano',
    require    => [
      File['/etc/systemd/system/gitnano.service'],
      Exec['gitnano-systemd-reload']
    ],
  }

  # 7. SSHD Anti-Hang Optimizations
  file_line { 'sshd_nodns':
    path   => '/etc/ssh/sshd_config',
    line   => 'UseDNS no',
    match  => '^#?UseDNS',
    notify => Service['ssh'],
  }

  file_line { 'sshd_nogssapi':
    path   => '/etc/ssh/sshd_config',
    line   => 'GSSAPIAuthentication no',
    match  => '^#?GSSAPIAuthentication',
    notify => Service['ssh'],
  }

  service { 'ssh':
    ensure => running,
    enable => true,
  }

  # 8. Cryptographic Keys and Loopback Handshake
  exec { 'generate_puppet_ssh_key':
    command => "ssh-keygen -t rsa -b 4096 -f ${private_key} -N '' -q",
    path    => ['/usr/bin', '/bin'],
    user    => 'root',
    creates => $private_key,
  }

  exec { 'sync_authorized_keys':
    command => "ssh-keygen -y -f ${private_key} > ${install_dir}/.ssh/authorized_keys",
    path    => ['/usr/bin', '/bin'],
    user    => 'root',
    creates => "${install_dir}/.ssh/authorized_keys",
    require => [Exec['generate_puppet_ssh_key'], File["${install_dir}/.ssh"]],
  }

  file { $puppet_ssh_dir:
    ensure  => directory,
    owner   => $puppet_user,
    group   => $puppet_user,
    mode    => '0700',
    require => Exec['generate_puppet_ssh_key'],
  }

  file { $private_key:
    ensure  => file,
    owner   => $puppet_user,
    group   => $puppet_user,
    mode    => '0600',
    require => Exec['generate_puppet_ssh_key'],
  }

  file { "${install_dir}/.ssh/authorized_keys":
    ensure  => file,
    owner   => $gitnano_user,
    group   => $gitnano_user,
    mode    => '0600',
    require => Exec['sync_authorized_keys'],
  }

  exec { 'seed_known_hosts':
    command => "ssh-keyscan -t rsa,ed25519 ${new_fqdn} localhost 127.0.0.1 >> /etc/ssh/ssh_known_hosts",
    path    => ['/usr/bin', '/bin'],
    unless  => "ssh-keygen -F localhost -f /etc/ssh/ssh_known_hosts",
    require => Service['ssh'],
  }

  # 9. Initial Repository Blueprint and Worktree Tracking
  exec { 'initialize_bare_repo':
    command => "git init --bare ${install_dir}/repos/${repo_name} && git -C ${install_dir}/repos/${repo_name} symbolic-ref HEAD refs/heads/production",
    path    => ['/usr/bin', '/bin'],
    user    => $gitnano_user,
    creates => "${install_dir}/repos/${repo_name}/HEAD",
    require => File["${install_dir}/repos"],
  }

  exec { 'migrate_gitlab_data':
    command     => "cd /tmp && MIGRATE_DIR=\$(mktemp -d) && chown ${gitnano_user} \$MIGRATE_DIR && sudo -u ${gitnano_user} git clone --mirror ${old_gitlab_url} \$MIGRATE_DIR && cd \$MIGRATE_DIR && sudo -u ${gitnano_user} git push --mirror ${install_dir}/repos/${repo_name} && cd /tmp && rm -rf \$MIGRATE_DIR",
    path        => ['/usr/bin', '/bin', '/usr/sbin', '/sbin'],
    refreshonly => true,
    subscribe   => Exec['initialize_bare_repo'],
  }

  exec { 'initialize_production_worktree':
    command     => "cd /tmp && rm -rf ${live_dir} && mkdir -p ${live_dir} && chown ${gitnano_user}:${gitnano_user} ${live_dir} && sudo -u ${gitnano_user} git clone --branch production ${install_dir}/repos/${repo_name} ${live_dir} && cd ${live_dir} && sudo -u ${gitnano_user} git remote add gitnano http://:@localhost:5000/${repo_name} && sudo -u ${gitnano_user} git config http.extraHeader 'Authorization: Bearer ${api_token}'",
    path        => ['/usr/bin', '/bin', '/usr/sbin', '/sbin'],
    refreshonly => true,
    subscribe   => Exec['migrate_gitlab_data'],
  }
}
