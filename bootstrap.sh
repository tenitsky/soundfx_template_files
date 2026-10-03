set -e
dns_ok() {
  timeout 10 getent ahostsv4 github.com >/dev/null 2>&1 &&
  timeout 10 getent ahostsv4 huggingface.co >/dev/null 2>&1
}
if ! dns_ok; then
  echo 'DNS lookup failed; retrying in 3 seconds...'
  sleep 3
  if ! dns_ok; then
    dns_backup=$(mktemp /tmp/soundfx-dns.XXXXXX)
    cp /etc/resolv.conf "$dns_backup"
    echo "Trying public DNS; original resolver saved at $dns_backup"
    if { printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\noptions timeout:2 attempts:2\n'; } > /etc/resolv.conf && dns_ok; then
      echo 'DNS recovered; continuing setup.'
    else
      cat "$dns_backup" > /etc/resolv.conf || true
      echo 'FATAL: DNS still unavailable or resolver is read-only. Check RunPod networking or deploy on another host with the same Network Volume.' >&2
      exit 1
    fi
  fi
fi
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  repo=$(mktemp -d /tmp/soundfx.XXXXXX)
  if git clone --depth 1 https://github.com/tenitsky/soundfx_template_files.git "$repo"; then
    exec bash "$repo/setup.sh"
  fi
  sleep 5
done
echo 'FATAL: unable to clone soundfx_template_files after 10 attempts' >&2
exit 1
