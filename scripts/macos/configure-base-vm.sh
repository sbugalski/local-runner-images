#!/bin/bash -e -o pipefail
################################################################################
##  File:  configure-base-vm.sh
##  Desc:  Runs inside the guest to give the base VM what the Anka source VMs
##         provide: passwordless sudo, SIP disabled and no sleep
################################################################################

if ! csrutil status | grep -Eq "System Integrity Protection status: (disabled|unknown)"; then
    echo "System Integrity Protection is enabled. Disable it from recoveryOS with 'csrutil disable' and rerun."
    exit 1
fi

echo "Allowing passwordless sudo for '$USERNAME'"
sudoers_file="/etc/sudoers.d/${USERNAME}-nopasswd"
echo "$PASSWORD" | sudo -S -p "" sh -c "echo '$USERNAME ALL=(ALL) NOPASSWD: ALL' > '$sudoers_file' && chmod 0440 '$sudoers_file'"
sudo -n visudo -cf "$sudoers_file"

echo "Disabling sleep so the build is not interrupted"
sudo -n pmset -a sleep 0 disksleep 0 displaysleep 0

echo "Disabling screen lock"
sysadminctl -screenLock off -password "$PASSWORD" || true
