#!/bin/bash -e -o pipefail
################################################################################
##  File:  utm-helpers.tests.sh
##  Desc:  Unit tests for the host-independent functions in utm-helpers.sh.
##         Run with the bash 3.2 that ships with macOS: bash utm-helpers.tests.sh
################################################################################

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$TESTS_DIR/../utm-helpers.sh"

failures=0

assert_equal() {
    local description=$1 expected=$2 actual=$3
    if [[ "$expected" == "$actual" ]]; then
        echo "[+] $description"
    else
        echo "[-] $description: expected '$expected', got '$actual'"
        failures=$((failures + 1))
    fi
}

assert_version_ge() {
    local version=$1 minimum=$2 expected=$3 actual=false
    version_ge "$version" "$minimum" && actual=true
    assert_equal "version_ge $version $minimum" "$expected" "$actual"
}

assert_version_ge "5.0.8" "5.0.8" true
assert_version_ge "5.0.9" "5.0.8" true
assert_version_ge "5.1" "5.0.8" true
assert_version_ge "10.0.0" "5.0.8" true
assert_version_ge "5.0.7" "5.0.8" false
assert_version_ge "4.9.9" "5.0.8" false
assert_version_ge "5" "5.0.1" false

leases=$(mktemp)
trap 'rm -f "$leases"' EXIT
cat > "$leases" <<EOF
{
	name=other
	ip_address=192.168.64.2
	hw_address=1,aa:bb:cc:dd:ee:ff
	identifier=1,aa:bb:cc:dd:ee:ff
	lease=0x6720f1a2
}
{
	name=runner
	ip_address=192.168.64.7
	hw_address=1,2:a:3f:4:5b:60
	identifier=1,2:a:3f:4:5b:60
	lease=0x6720f1b3
}
EOF

assert_equal "lease lookup strips leading zeros from MAC octets" \
    "192.168.64.7" "$(ip_from_dhcp_leases "02:0A:3F:04:5B:60" "$leases")"
assert_equal "lease lookup matches a MAC without leading zeros" \
    "192.168.64.2" "$(ip_from_dhcp_leases "aa:bb:cc:dd:ee:ff" "$leases")"
assert_equal "lease lookup prints nothing for an unknown MAC" \
    "" "$(ip_from_dhcp_leases "02:00:00:00:00:01" "$leases")"
assert_equal "lease lookup prints nothing without a leases file" \
    "" "$(ip_from_dhcp_leases "02:0a:3f:04:5b:60" "/nonexistent/dhcpd_leases")"

tags="ubuntu24-arm64/20261012.149
ubuntu24-arm64/20261026.166
ubuntu24-arm64/20261026.99
ubuntu24-arm64/20261023.149
ubuntu24-arm64-test/20261030.1
ubuntu24-arm64/latest
ubuntu24/20261030.1"
assert_equal "latest tag is the newest date, then the highest build number" \
    "ubuntu24-arm64/20261026.166" "$(echo "$tags" | select_latest_tag "ubuntu24-arm64")"
assert_equal "latest tag ignores other images and non-release tags" \
    "ubuntu24/20261030.1" "$(echo "$tags" | select_latest_tag "ubuntu24")"
assert_equal "latest tag prints nothing without releases" \
    "" "$(echo "$tags" | select_latest_tag "macos-26-arm64")"

assert_equal "explicit version gets the image prefix" \
    "macos-26-arm64/20261021.0445" "$(resolve_image_tag "macos-26-arm64" "20261021.0445")"
assert_equal "explicit full tag is kept" \
    "macos-26-arm64/20261021.0445" "$(resolve_image_tag "macos-26-arm64" "macos-26-arm64/20261021.0445")"
assert_equal "a tag of another image is rejected" \
    "rejected" "$( (resolve_image_tag "macos-26-arm64" "ubuntu24-arm64/20261026.166" 2>/dev/null) || echo rejected)"

runner_tags="v2.338.2
v2.338.10
v2.99.0
v3.0.0-beta.1
latest"
assert_equal "newest runner version compares numerically and skips pre-releases" \
    "2.338.10" "$(echo "$runner_tags" | select_latest_runner_version)"

set_source_repo ""
assert_equal "tags come from the fork by default" "$FORK_REPO" "$SOURCE_REPO"
set_source_repo upstream
assert_equal "--repo upstream uses actions/runner-images" "$UPSTREAM_REPO" "$SOURCE_REPO"
set_source_repo "https://example.com/runner-images.git"
assert_equal "--repo accepts a git URL" "https://example.com/runner-images.git" "$SOURCE_REPO"

if (( failures > 0 )); then
    echo "$failures test(s) failed"
    exit 1
fi
echo "All tests passed"
