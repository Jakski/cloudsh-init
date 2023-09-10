#!/bin/dash

set -eu

on_exit() {
	local \
		exit_code=$? \
		pid
	if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
		if findmnt "$TMP_DIR" >/dev/null; then
			umount "$TMP_DIR"
		fi
		rm -rf "$TMP_DIR"
	fi
	# shellcheck disable=SC2016
	pid=$(dash -c 'echo $PPID')
	if [ "$exit_code" != 0 ]; then
		printf  "%s\n" "Process ${pid} exited with code ${exit_code}" >&2
	fi
	exit "$exit_code"
}

get_cidata_disk() {
	local \
		vars="" \
		found=0 \
		line \
		type \
		label \
		devname
	blkid --output export | while read -r line; do
		if [ "$found" = 1 ]; then
			continue
		fi
		if [ -z "$line" ]; then
			vars=""
		else
			vars=$(printf "%s\n" "$vars" "$line")
			type=$(eval "$vars"; echo "${TYPE:-}")
			label=$(eval "$vars"; echo "${LABEL:-}")
			devname=$(eval "$vars"; echo "${DEVNAME:-}")
			if \
				{ [ "${type:-}" = "vfat" ] || [ "${type:-}" = "iso9660" ]; } \
					&& { [ "${label:-}" = "cidata" ] || [ "${label:-}" = "CIDATA" ]; }
			then
				found=1
				printf "%s" "$devname"
			fi
		fi
	done
}

mount_cidata_disk() {
	local disk
	disk=$(get_cidata_disk)
	if [ -z "$disk" ]; then
		printf "%s\n" "No cidata disks have been found"
		exit 0
	fi
	mount -o ro "$disk" "$TMP_DIR"
}

install_services() {
	local \
		f \
		dep
	for dep in \
		systemctl \
		blkid \
		uniq \
		sort \
		wc \
		findmnt \
		mount \
		umount
	do
		if ! command -v "$dep" >/dev/null; then
			printf "%s\n" "Command ${dep} is missing" >&2
			return 1
		fi
	done
	f="/etc/systemd/system/cloudsh-init-local.service"
	printf "%s\n" "Writing ${f}"
printf "%s\n" \
"[Unit]
Description=Pre networking cloudsh-init
DefaultDependencies=no
Wants=network-pre.target
After=hv_kvp_daemon.service
After=systemd-remount-fs.service
Before=NetworkManager.service
Before=network-pre.target
Before=shutdown.target
Before=sysinit.target
Conflicts=shutdown.target

[Service]
Type=oneshot
ExecStart=${0} run local
RemainAfterExit=yes
TimeoutSec=0
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target" >"$f"
	f="/etc/systemd/system/cloudsh-init-final.service"
	printf "%s\n" "Writing ${f}"
printf "%s\n" \
"[Unit]
Description=Final cloudsh-init
After=network-online.target rc-local.service
Before=apt-daily.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${0} run final
RemainAfterExit=yes
TimeoutSec=0
TasksMax=infinity
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target" >"$f"
	printf "%s\n" "Reloading systemd"

	systemctl daemon-reload
	printf "%s\n" "Enabling services"
	systemctl enable \
		cloudsh-init-local.service \
		cloudsh-init-final.service
}

print_help() {
printf "%s\n" \
"Instance initialization script.

Options:
  -h|--help   Show this message

Subcommands:
  run SCRIPT  Run selected script from cidata disk
  install     Setup system services"
}

main() {
	trap on_exit EXIT
	case "${1:-}" in
		-h|--help)
			print_help
			;;
		run)
			TMP_DIR=$(mktemp -d /run/cloudsh-init.XXXXXX)
			mount_cidata_disk
			"${TMP_DIR}/${2}"
			;;
		install)
			install_services
			;;
		*)
			print_help
			return 1
			;;
	esac
}

main "$@"
