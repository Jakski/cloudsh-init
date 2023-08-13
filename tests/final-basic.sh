#!/bin/bash

set -eu

main() {
	ip route get 1.1.1.1 >/dev/null
	echo "Finished running cloudsh-init final"
	poweroff
}

main "$@"
