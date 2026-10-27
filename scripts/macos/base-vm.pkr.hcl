// Prepares a freshly installed UTM macOS VM so it can serve as the source VM
// for the macOS image templates (builder_type = "null").
// Run by create-base-vm.sh, see docs/create-image-utm.md.

variable "vm_host" {
  type = string
}

variable "vm_username" {
  type = string
}

variable "vm_password" {
  type      = string
  sensitive = true
}

source "null" "base" {
  ssh_host     = "${var.vm_host}"
  ssh_username = "${var.vm_username}"
  ssh_password = "${var.vm_password}"
  ssh_timeout  = "10m"
}

build {
  sources = ["source.null.base"]

  provisioner "shell" {
    environment_vars = ["USERNAME=${var.vm_username}", "PASSWORD=${var.vm_password}"]
    execute_command  = "chmod +x {{ .Path }}; {{ .Vars }} {{ .Path }}"
    script           = "${path.root}/configure-base-vm.sh"
  }
}
