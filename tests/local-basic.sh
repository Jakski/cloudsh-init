#!/bin/dash

set -eu

HOSTNAME="cloudsh-init-test"
USER="admin"
SSH_KEYS="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK86cPVw/blQCfxiPt5QZEj74D6t/LtBGny1FkWVSIoM test"

echo() {
	printf "%s\n" "$@"
}

render_hosts() {
printf "%s\n" \
"127.0.0.1 localhost
127.0.1.1 ${HOSTNAME}

# The following lines are desirable for IPv6 capable hosts
::1 ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
ff02::3 ip6-allhosts
"
}

main() {
	local \
		rendered \
		current \
		f

	f="/etc/hostname"
	echo "Comparing ${f}"
	current=$(cat "$f")
	if [ "$current" != "$HOSTNAME" ]; then
		echo "Writing ${f}"
		echo "$HOSTNAME" >"$f"
	fi

	f="/etc/hosts"
	echo "Comparing ${f}"
	current=$(cat "$f")
	rendered=$(render_hosts)
	if [ "$current" != "$rendered" ]; then
		echo "Writing ${f}"
		printf "%s" "$rendered" >"$f"
	fi

	f="/home/${USER}/.ssh"
	mkdir -p "$f"
	chown ${USER}:${USER} "$f"
	chmod 700 "$f"

	f="${f}/authorized_keys"
	echo "Writing ${f}"
	touch "$f"
	chown ${USER}:${USER} "$f"
	chmod 600 "$f"
	printf "%s\n" "$SSH_KEYS" >"$f"
	echo "Finished running cloudsh-init local"
}

main "$@"
