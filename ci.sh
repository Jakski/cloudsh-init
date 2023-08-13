#!/usr/bin/env bash

set -euo pipefail
shopt -s inherit_errexit nullglob lastpipe

declare \
	SCRIPT_DIR \
	SCRIPT_FILE
SCRIPT_FILE=$(readlink -f "$BASH_SOURCE")
SCRIPT_DIR=$(dirname "$SCRIPT_FILE")

safe_echo() {
	printf "%s\n" "$@"
}

on_exit() {
	declare \
		cmd=$BASH_COMMAND \
		exit_code=$? \
		i=0 \
		line=""
	declare -a \
		all_functions=() \
		parts
	if [ "$exit_code" != 0 ] && [ "${HANDLED_ERROR:-}" != 1 ]; then
		echo "Process ${BASHPID} exited with code ${exit_code} in command: ${cmd}" 1>&2
		while true; do
			line=$(caller "$i") || break
			echo "  ${line}" 1>&2
			i=$((i + 1))
		done
		HANDLED_ERROR=1
	fi
	declare -F | mapfile -t all_functions
	for i in "${all_functions[@]}"; do
		if [[ $i =~ declare[[:space:]]-f[[:space:]]on_exit_[^[:space:]]+$ ]]; then
			read -r -a parts <<< "$i"
			"${parts[2]}"
		fi
	done
	exit "$exit_code"
}

on_error() {
	declare \
		cmd=$BASH_COMMAND \
		exit_code=$? \
		i=0 \
		line=""
	echo "Process ${BASHPID} exited with code ${exit_code} in command: ${cmd}" 1>&2
	while true; do
		line=$(caller "$i") || break
		echo "  ${line}" 1>&2
		i=$((i + 1))
	done
	HANDLED_ERROR=1
	exit "$exit_code"
}

install_dependencies() {
	declare -a pkgs=()
	declare image="${SCRIPT_DIR}/.cache/debian-12-genericcloud-amd64.qcow2"
	if ! command -v genisoimage >/dev/null; then
		pkgs+=(genisoimage)
	fi
	if ! command -v qemu-system-x86_64 >/dev/null; then
		pkgs+=(qemu-system-x86)
	fi
	if ! command -v qemu-img >/dev/null; then
		pkgs+=(qemu-utils)
	fi
	if ! command -v wget >/dev/null; then
		pkgs+=(wget)
	fi
	if [ "${#pkgs[@]}" != 0 ]; then
		if [ "$UID" != 0 ]; then
			sudo apt-get install -y "${pkgs[@]}"
		else
			apt-get install -y "${pkgs[@]}"
		fi
	fi
	if [ ! -f "$image" ]; then
		echo "Downloading Debian cloud image"
		wget -q \
			-O "$image" \
			"https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
	fi
	echo "Creating base instance image"
	qemu-img create -q -f qcow2 -b "$image" -F qcow2 "${TMP_DIR}/rootfs.qcow2"
}

create_target_cidata() {
	echo "Creating target cidata disk"
	mkdir "${TMP_DIR}/cidata"
	(
		pushd "${TMP_DIR}/cidata" >/dev/null
		cp "${SCRIPT_DIR}/tests/local-basic.sh" "local"
		cp "${SCRIPT_DIR}/tests/final-basic.sh" "final"
		genisoimage -quiet -output cidata.iso -volid cidata -joliet -rock "local" "final"
	)
}

create_migration_cidata() {
	declare -a \
		content \
		script
	echo "Creating migration cidata disk"
	mkdir "${TMP_DIR}/migrate-cidata"
	(
		pushd "${TMP_DIR}/migrate-cidata" >/dev/null
		mapfile -d "" content <<EOF
instance-id: cloudsh-init-test
local-hostname: cloudsh-init-test
EOF
		printf "%s" "$content" >"meta-data"
		gzip < "${SCRIPT_DIR}/cloudsh-init.sh" \
			| base64 -w 0 \
			| mapfile -d "" script
		mapfile -d "" content <<EOF
#cloud-config
bootcmd:
  - systemctl mask --now unattended-upgrades
runcmd:
  - /usr/local/sbin/cloudsh-init install
  - apt-get purge -y cloud-init; poweroff
users:
  - name: admin
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
write_files:
  - path: /usr/local/sbin/cloudsh-init
    encoding: gzip
    permissions: '0755'
    content: !!binary ${script}
EOF
		printf "%s" "$content" >"user-data"
		genisoimage -quiet -output cidata.iso -volid cidata -joliet -rock user-data meta-data
	)
}

run_tests() {
	install_dependencies
	create_migration_cidata
	create_target_cidata
	echo "Migrating instance from cloud-init to cloudsh-init"
	(
		pushd "${TMP_DIR}" >/dev/null
		qemu-system-x86_64 \
			-m 512 \
			-smp 1 \
			-netdev user,id=user0 \
			-device virtio-net-pci,netdev=user0 \
			-drive file=rootfs.qcow2,format=qcow2,id=disk0,if=none,index=0 \
			-device virtio-blk-pci,drive=disk0,bootindex=1 \
			-drive file=migrate-cidata/cidata.iso,format=raw,if=virtio \
			-monitor unix:monitor.socket,server,nowait \
			-chardev socket,id=char0,path=console.socket,logfile=console.log,server,nowait \
			-serial chardev:char0 \
			-nographic \
			-pidfile pid.txt
	)
	echo "Running test in instance"
	(
		pushd "${TMP_DIR}" >/dev/null
		qemu-system-x86_64 \
			-m 512 \
			-smp 1 \
			-netdev user,id=user0 \
			-device virtio-net-pci,netdev=user0 \
			-drive file=rootfs.qcow2,format=qcow2,id=disk0,if=none,index=0 \
			-device virtio-blk-pci,drive=disk0,bootindex=1 \
			-drive file=cidata/cidata.iso,format=raw,if=virtio \
			-monitor unix:monitor.socket,server,nowait \
			-chardev socket,id=char0,path=console.socket,logfile=console.log,server,nowait \
			-serial chardev:char0 \
			-nographic \
			-pidfile pid.txt
		grep -E 'cloudsh-init\[[0-9]+\]: Finished running cloudsh-init local' console.log >/dev/null
		grep -E 'cloudsh-init\[[0-9]+\]: Finished running cloudsh-init final' console.log >/dev/null
		echo "Verified, that cloudsh-init has been run"
	)
}

on_exit_remove_tmpdir() {
	if [ -v TMP_DIR ]; then
		rm -rf "$TMP_DIR"
	fi
}

main() {
	trap on_exit EXIT
	trap on_error ERR
	TMP_DIR=$(mktemp -d)
	printf "%s\n" "Temporary directory: ${TMP_DIR}"
	mkdir -p "${SCRIPT_DIR}/.cache"
	case "${1:-}" in
		test)
			run_tests
			;;
		*)
			safe_echo "Wrong option: ${1:-}" >&2
			return 1
			;;
	esac
}

main "$@"
