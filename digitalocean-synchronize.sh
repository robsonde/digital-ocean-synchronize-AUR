#!/bin/bash

# Copyright (c) 2017 Gavin Li.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of
# this software and associated documentation files (the "Software"), to deal in
# the Software without restriction, including without limitation the rights to
# use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
# of the Software, and to permit persons to whom the Software is furnished to do
# so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# DigitalOcean metadata API
# https://developers.digitalocean.com/documentation/metadata/
meta_base=http://169.254.169.254/metadata/v1/

set -eu
set -o pipefail
shopt -s nullglob
shopt -s dotglob
umask 022

log() {
	logger -t digitalocean-synchronize "$@" || \
		echo "[$(date)]" "$@" >&2
}

netmask_to_prefix() {
	local pfx=0 cmp msk
	for cmp in ${1//./ } 0; do
		for msk in 128 64 32 16 8 4 2 1; do
			if (( cmp & msk )); then
				(( pfx += 1 ))
			else
				echo ${pfx}
				return
			fi
		done
	done
}

do_curl() {
	local retry
	local result
	for retry in {1..20}; do
		if result=$(curl -sf -m 1 ${1}); then
			log "Got a result of ${result} from a query of ${1}"
			printf '%s' "${result}"
			break
		else
			log "Unable get result for ${1}"
			sleep 1
		fi
	done
}

update_shadow_if_changed() {
	local etcdir=$1/etc
	mkdir -p ${etcdir} || return 0
	if [ -e ${etcdir}/shadow ]; then
		# change password if file was touched
		local encrypted_password=$(awk -F: '$1 == "root" { print $2 }' ${etcdir}/shadow)
		if [ "${encrypted_password}" != "z" ]; then
			log "Snapshot restore detected."
			usermod -p "${encrypted_password}" root
			if [ ${#encrypted_password} -gt 1 ]; then
				chage -d 0 root
			fi
			log "Password has been reset."
			rm -f /etc/ssh/ssh_host_key /etc/ssh/ssh_host_*_key
			log "SSH host keys will be regenerated."
		fi
	fi
	cat > ${etcdir}/shadow <<-EOF
		root:z:1::::::
		nobody:z:1::::::
	EOF
	chmod 0600 ${etcdir}/shadow
}

process_interface() {
	local url=$1
	local attrs=$2
	local mac=$(do_curl ${url}mac)
	local type=$(do_curl ${url}type)
	local interface=
	local cand path
	for cand in $(ls /sys/class/net); do
		path=/sys/class/net/${cand}/address
		if [ -e ${path} ] && [ "$(<${path})" = "${mac}" ]; then
			interface=${cand}
			break
		fi
	done
	[ -n "${interface}" ] || return 0
	mkdir -p /run/systemd/network
	{
		cat <<-EOF
			# Generated by digitalocean-synchronize
			[Match]
			Name=${interface}
			[Network]
		EOF
		if [[ " ${attrs} " =~ " ipv4/ " ]]; then

			local netmask=$(do_curl ${url}ipv4/netmask)
			local address=$(do_curl ${url}ipv4/address)
			local prefix=$(netmask_to_prefix ${netmask})
			echo "Address=${address}/${prefix}"
			if [ "${type}" != "private" ]; then
				echo "Gateway=$(do_curl ${url}ipv4/gateway)"
			fi
			log "Added IPv4 address ${address}/${prefix} on ${interface}."
		fi
		if [[ " ${attrs} " =~ " anchor_ipv4/ " ]]; then
			local address=$(do_curl ${url}anchor_ipv4/address)
			local prefix=$(netmask_to_prefix $(do_curl ${url}anchor_ipv4/netmask))
			echo "Address=${address}/${prefix}"
			log "Added Anchor IPv4 address ${address}/${prefix} on ${interface}."
		fi
		if [[ " ${attrs} " =~ " ipv6/ " ]]; then
			local address=$(do_curl ${url}ipv6/address)
			local prefix=$(do_curl ${url}ipv6/cidr)
			echo "Address=${address}/${prefix}"
			if [ "${type}" != "private" ]; then
				echo "Gateway=$(do_curl ${url}ipv6/gateway)"
			fi
			log "Added IPv6 address ${address}/${prefix} on ${interface}."
		fi
		local network_tail=/etc/systemd/network/template/dosync-${interface}.network.tail
		if [[ -r "${network_tail}" ]]; then
			cat ${network_tail}
			log "Appended user specified config for ${interface}."
		fi
	} > /run/systemd/network/dosync-${interface}.network
}

traverse_interfaces() {
	local url=$1
	set -- $(do_curl ${url})
	if [[ " $* " =~ " mac " ]]; then
		process_interface ${url} "$*"
	else
		local dir
		for dir in $*; do
			# only want dirs with slash suffix
			[ "${dir}" = "${dir%/}" ] && continue
			traverse_interfaces ${url}${dir}
		done
	fi
}

setup_from_metadata_service() {
	local sshkeys
	if sshkeys=$(do_curl ${meta_base}public-keys) && test -n "${sshkeys}"; then
		[ -d /root/.ssh ] || mkdir -m 0700 /root/.ssh
		[ -e /root/.ssh/authorized_keys ] || touch /root/.ssh/authorized_keys
		if ! grep -q "${sshkeys}" /root/.ssh/authorized_keys; then
			printf '\n%s\n' "${sshkeys}" >> /root/.ssh/authorized_keys
			log "Added SSH public keys from metadata service."
		fi
	fi
	local hostname
	if ! test -e /etc/hostname && hostname=$(do_curl ${meta_base}hostname); then
		echo "${hostname}" > /etc/hostname
		hostname "${hostname}"
		log "Hostname set to ${hostname} from metadata service."
	fi
	traverse_interfaces ${meta_base}interfaces/
}

digitalocean_synchronize() {
	if test -e /dev/disk/by-label/DOROOT && mkdir -p /mnt/doroot; then
		mount /dev/disk/by-label/DOROOT /mnt/doroot
		update_shadow_if_changed /mnt/doroot
		umount /mnt/doroot
	else
		log "Unable to check DOROOT for snapshot check!"
	fi

	ip link set dev eth0 up
	ip addr add dev eth0 169.254.169.252/30 2>/dev/null || true
	local retry
	for retry in {1..20}; do
		log "Attempting to connect to metadata service ..."
		if curl -sf -m 1 ${meta_base} >/dev/null; then
			setup_from_metadata_service
			break
		else
			log "Unable to connect to metadata service!"
			sleep 1
		fi
	done
	ip addr del dev eth0 169.254.169.252/30 2>/dev/null || true
}

digitalocean_synchronize
