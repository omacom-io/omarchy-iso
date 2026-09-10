#!/bin/bash

# Real legacy Docker fixtures in a disposable ISO guest. Never run this script
# directly on a development desktop: the harness owns the guest and its disk.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
base_image_ready || { echo "Run this through ./test/integration" >&2; exit 1; }
start_vm_from_base
wait_for_ssh "$BOOT_TIMEOUT"
ssh_sudo "printf '%s\n' '$GUEST_USER ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/90-container-test; chmod 440 /etc/sudoers.d/90-container-test"

ssh_guest 'cat >/tmp/podman-migration-fixture.sh' <<'GUEST'
#!/bin/bash
set -euo pipefail
[[ $(hostname) == "omarchy-test" ]] || exit 1
export OMARCHY_PATH=/usr/share/omarchy
export XDG_RUNTIME_DIR=/run/user/$(id -u)
unset DOCKER_HOST
# Fresh offline installs intentionally omit synchronized repository databases.
# Refresh only this disposable fixture's indexes; keep the built runtime pinned.
sudo pacman -Sy --noconfirm
omarchy-pkg-drop podman-docker
omarchy-pkg-add docker
sudo systemctl start docker.socket
sudo docker run -d --name redis --restart unless-stopped \
  -p 127.0.0.1:6379:6379 \
  --health-cmd 'redis-cli ping' --health-interval 1s --health-timeout 1s --health-retries 5 \
  docker.io/library/redis:7
sudo docker run -d --name postgres16 --restart unless-stopped \
  -p 127.0.0.1:5432:5432 \
  -e POSTGRES_PASSWORD=fixture-only docker.io/library/postgres:16
for attempt in {1..60}; do
  sudo docker exec postgres16 pg_isready -U postgres && break
  sleep 1
done
sudo docker exec postgres16 psql -U postgres -c "CREATE TABLE migration_proof (value text); INSERT INTO migration_proof VALUES ('preserved');"
sudo docker exec redis redis-cli SET migration-proof preserved
sudo docker exec redis sh -c 'echo writable-layer >/migration-proof'
sudo docker stop postgres16

# Stock installers rely on the image's anonymous VOLUME. Explicit -v/--mount
# configuration is deliberately outside automatic migration's accepted scope.
volume_name=$(sudo docker inspect postgres16 --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}')
volume=$(sudo docker volume inspect "$volume_name" --format '{{.Mountpoint}}')
sudo python3 - "$volume" <<'PY'
from pathlib import Path
import os,sys
p=Path(sys.argv[1]);p.chmod(0o775)
f=p/'metadata-proof';f.write_bytes(b'preserved metadata\n');f.chmod(0o640)
os.chown(f,1000,1000);os.setxattr(f,'user.migration',b'preserved')
os.link(f,p/'hardlink-proof');(p/'symlink-proof').symlink_to('metadata-proof')
os.utime(f,ns=(1720000000123456789,1720000000123456789))
PY
sudo setfacl -m u:1234:r "$volume/metadata-proof"
# One unsupported workload must reject the entire batch while Redis stays up.
sudo docker run -d --name custom-project docker.io/library/redis:7 sleep infinity
if bash -euo pipefail "$OMARCHY_PATH/migrations/1788886195.sh"; then
  echo 'Unsupported container incorrectly passed migration' >&2; exit 1
fi
[[ $(sudo docker inspect redis --format '{{.State.Running}}') == "true" ]]
! podman container exists redis
sudo docker rm -f custom-project
bash -euo pipefail "$OMARCHY_PATH/migrations/1788886195.sh"
[[ $(pacman -Qq docker) == "podman-docker" ]]
[[ $(podman exec redis redis-cli GET migration-proof) == "preserved" ]]
[[ $(podman exec redis cat /migration-proof) == "writable-layer" ]]
[[ $(podman inspect postgres16 --format '{{.State.Running}}') == "false" ]]
[[ $(podman inspect redis --format '{{.HostConfig.PidsLimit}}') == "-1" ]]
for attempt in {1..30}; do
  [[ $(podman inspect redis --format '{{.State.Health.Status}}') == "healthy" ]] && break
  sleep 1
done
[[ $(podman inspect redis --format '{{.State.Health.Status}}') == "healthy" ]]
target=$(podman volume inspect "omarchy-migrated-$volume_name" --format '{{.Mountpoint}}')
podman unshare python3 - "$target" <<'PY'
import os,sys
from pathlib import Path
p=Path(sys.argv[1]);f=p/'metadata-proof';s=f.stat()
assert p.stat().st_mode & 0o777==0o775
assert s.st_uid==1000 and s.st_gid==1000
assert s.st_mtime_ns==1720000000123456789
assert os.getxattr(f,'user.migration')==b'preserved'
assert os.getxattr(f,'system.posix_acl_access')
assert s.st_ino==(p/'hardlink-proof').stat().st_ino
assert (p/'symlink-proof').readlink()==Path('metadata-proof')
PY
podman start postgres16
for attempt in {1..60}; do
  podman exec postgres16 pg_isready -U postgres && break
  sleep 1
done
[[ $(podman exec postgres16 psql -U postgres -Atc 'SELECT value FROM migration_proof') == "preserved" ]]
podman stop postgres16
# Retrying after Docker removal must preserve both destinations and their data.
bash -euo pipefail "$OMARCHY_PATH/migrations/1788886195.sh"
sudo test -d /var/lib/docker
printf 'LIVE MIGRATION VERIFIED\n'
GUEST
ssh_guest 'bash /tmp/podman-migration-fixture.sh' >"$RUN_DIR/migration.log" 2>&1 || {
  cat "$RUN_DIR/migration.log"; capture_console failure-podman-migration; exit 1;
}
capture_console success-podman-migration
old_boot=$(ssh_guest 'cat /proc/sys/kernel/random/boot_id')
ssh_sudo 'systemctl reboot' || true
sleep 10
wait_for_ssh "$BOOT_TIMEOUT"
check "guest rebooted" ssh_guest "test \"\$(cat /proc/sys/kernel/random/boot_id)\" != '$old_boot'"
check "running Redis resumed with data" ssh_guest "test \"\$(podman exec redis redis-cli GET migration-proof)\" = preserved"
check "deliberately stopped PostgreSQL remains stopped" ssh_guest "test \"\$(podman inspect postgres16 --format '{{.State.Running}}')\" = false"
check "Docker bridge and firewall chains are gone" ssh_sudo '! ip link show docker0 2>/dev/null && ! iptables-save | grep -q DOCKER'
check "rootless API responds after reboot" ssh_guest 'curl -fsS --max-time 10 --unix-socket "$XDG_RUNTIME_DIR/podman/podman.sock" http://localhost/_ping'
capture_console success-podman-migration-reboot
finish
