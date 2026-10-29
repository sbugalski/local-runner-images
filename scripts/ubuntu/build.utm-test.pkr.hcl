# An empty Ubuntu build for testing the UTM build flow in a few minutes:
# connecting to the VM, the power off that replaces the reboot step of the
# image templates, the VM watchdog and reconnecting after the cold start.
# build-image.sh --test-template uses it in place of the image template, next
# to the null source and the variables written by generate-template.sh

build {
  sources = ["source.null.image"]
  name    = "ubuntu-utm-test"

  provisioner "shell" {
    inline = [
      "cloud-init status --wait >/dev/null || true",
      "echo \"Kernel $(uname -r), boot $(cat /proc/sys/kernel/random/boot_id)\"",
      "cat /proc/sys/kernel/random/boot_id > /var/tmp/utm-test-boot-id"
    ]
  }

  # Same step as generate-template.sh writes for 'Reboot VM'
  provisioner "shell" {
    execute_command   = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    expect_disconnect = true
    inline            = ["echo 'Power off VM, the build script starts it again'", "sudo systemctl poweroff"]
  }

  provisioner "shell" {
    pause_before        = "1m0s"
    start_retry_timeout = "10m"
    inline = [
      "echo \"Boot $(cat /proc/sys/kernel/random/boot_id)\"",
      "if [ \"$(cat /proc/sys/kernel/random/boot_id)\" = \"$(cat /var/tmp/utm-test-boot-id)\" ]; then echo 'The VM did not restart' >&2; exit 1; fi",
      "echo \"systemd: $(systemctl is-system-running --wait)\""
    ]
  }
}
