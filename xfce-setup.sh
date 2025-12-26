#!/usr/bin/env bash

#  xfce-setup.sh
#
#  A simple bash script to set up a Fedora Xfce Minimal Workstation
#
#  Repo: github.com/kuladog/fedora-xfce-minimal
#  Revised: 2025-12-26
#

set -euo pipefail
IFS=$'\n\t'

exec > >(tee ../fedora-setup.log) 2>/dev/tty

DIR=$(dirname "${BASH_SOURCE[0]}")
HOST="$(hostname -s)"
NAME="$(logname)"

#================================================
#    USER CHECK
#================================================

clear

root_check() {
	if [[ $EUID -ne 0 ]]; then
	  echo "Run the script as root."
	  exit 1
	fi
}

user_confirm() {
	echo -e "\n This will modify system configurations and install additional packages.\n"
	echo -n " Are you sure you want to continue? [Y/n]: "
	read -r confirm
	c="${confirm:-y}"

	if [[ ! $c =~ ^[Yy]$ ]]; then
		echo -e "\nSetup aborted."
		exit 0
	fi
}

root_check
user_confirm

#================================================
#    PACKAGE MANAGEMENT
#================================================

source_applications() {
	# Exit setup if apps can't be installed
	if [[ -f ${DIR}/applications ]]; then
		source "${DIR}"/applications
	else
		echo "Error: 'applications' file not found."
		exit 1
	fi
}

source_bloatware() {
	# Continue if no 'bloatware' file found
	if [[ -f ${DIR}/bloatware ]]; then
		source "${DIR}"/bloatware
	else
		echo "Warning: 'bloatware' file not found."
	fi
}

add_repositories() {
	echo -e "\nEnabling additional repositories ..."

	# Enable RPM Fussion repos
	dnf install -y \
	https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
	https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm

	# Enable erizur/firefox-esr
	dnf copr enable -y erizur/firefox-esr

	# Enable nordvpn repo
	rpm -v --import "https://repo.nordvpn.com/gpg/nordvpn_public.asc"
	dnf config-manager addrepo \
	--overwrite --set=baseurl=https://repo.nordvpn.com/yum/nordvpn/centos/x86_64
}

install_packages() {
	echo -e "\nInstalling additional packages ..."

	PKGS=(${GROUP_PACKAGES[@]} ${XFCE_PACKAGES[@]} ${ADDON_PACKAGES[@]})

	dnf install -y --skip-unavailable --allowerasing "${PKGS[@]}"

	# Check if running in VM
	if [[ $(systemd-detect-virt) != none ]]; then
		echo -e "\nInstalling guest agents ...\n"
		dnf install -y qemu-guest-agent spice-vdagent
	fi
}

install_theme() {
	local theme_dir="/home/${NAME}/.themes"

	curl -LO https://github.com/kuladog/adwaita-grey-dark/archive/refs/heads/main.zip

	if [[ -f ${DIR}/main.zip ]]; then
		echo -e "\nInstalling desktop theme ..."

		unzip main.zip
		mkdir -p "$theme_dir"
		mv *grey-dark*/ "${theme_dir}"/Adwaita-grey-dark
	fi
}

remove_bloatware() {
	echo -e "\nRemoving unwanted packages ..."

	# Need to loop when removing
	if [[ -f ${DIR}/bloatware ]]; then
		for package in "${BLOATWARE_PACKAGES[@]}"; do
			echo -e "\nRemoving $package ...\n"
			dnf -y remove "$package"
		done
	fi
}

source_applications
source_bloatware
add_repositories
install_packages
install_theme
remove_bloatware

#================================================
#    SYSTEM CONFIGURATION
#================================================

copy_configs() {
	echo -e "\nCopying configuration files ..."

	# Set user, host and copy
	if [[ -d ${DIR}/configs ]]; then
		find "${DIR}"/configs -type f | while read -r file; do
			dest="/etc/${file#${DIR}/configs/}"
			mkdir -p "$(dirname "$dest")"
			sed -e "s|<user>|${NAME}|" -e "s|<host>|${HOST}|" "$file" > "$dest"
		done
	fi

	chown -R root:root /etc
}

grub_config() {
	echo -e "\nUpdating GRUB configuration ..."

	# Rebuild the grub.cfg
	if [[ -f /etc/default/grub ]]; then
		grub2-mkconfig -o /boot/grub2/grub.cfg
	fi
}

fstab_config() {
    echo -e "\nConfiguring filesystem table ..."

	local fstable="/etc/fstab"

	# Backup fstab and edit in place
	if [[ -w /etc/fstab ]]; then
		sed -i \
		-e '/boot/ s=relatime=noatime=' \
		-e '/\/[[:space:]]/ s=relatime=noatime=' \
		-e '/home\|var/ s=defaults=noatime,nodev,nosuid=' \
		-e 's/\S\+/0/5' \
		-e 's/\S\+/0/6' \
		"$fstable"

		{
		echo "tmpfs /tmp        tmpfs   nodev,nosuid,noexec 0 0"
		echo "tmpfs /var/tmp    tmpfs   nodev,nosuid,noexec 0 0"
		echo "tmpfs /dev/shm    tmpfs   nodev,nosuid,noexec 0 0"
		} >> "$fstable"
	fi
}

lightdm_config() {
	echo -e "\nConfiguring display manager ..."

	# Warn if not installed
	if command -v lightdm &>/dev/null; then
		systemctl enable lightdm
		systemctl set-default graphical.target
	else
		echo "WARNING: LightDM is not installed."
	fi
}

set_libvirt() {
	# Add user to group
	if command -v libvirtd &>/dev/null; then
		echo -e "\nConfiguring virt-manager ..."

		usermod -aG libvirt "$NAME"
	fi
}

copy_configs
grub_config
fstab_config
lightdm_config
set_libvirt

#================================================
#    SYSTEM SECURITY
#================================================

dnf_security() {
	# Enable if installed
	if command -v dnf-automatic &>/dev/null; then
		echo -e "\nEnabling DNF security updates ..."

		systemctl enable --now dnf-automatic.timer
	fi
}

firewalld_config() {
	ruleset=(
		--set-default-zone=drop
		--add-service=https
		--add-icmp-block-inversion
		)

	if command -v firewalld &>/dev/null; then
		echo -e "\nConfiguring Firewalld ..."

		# Set firewall defaults
		for rule in "${ruleset[@]}"; do
			firewall-cmd "$rule"
		done
	fi
}

firejail_config() {
	if command -v firejail &>/dev/null; then
		echo -e "\nConfiguring Firejail ..."

		# Create firejail group
		if ! getent group firejail &>/dev/null; then
			groupadd firejail
		fi

		# Add user to firejail group
		if ! groups "$NAME" | grep -q firejail; then
			usermod -aG firejail "$NAME"
		fi

		chown root:firejail /usr/bin/firejail
		chmod 4750 /usr/bin/firejail

		firecfg
	fi
}

nordvpn_config() {
	if command -v nordvpn &>/dev/null; then
		echo -e "\nConfiguring NordVPN ..."

		if ! groups "$NAME" | grep -q nordvpn; then
			usermod -aG nordvpn "$NAME"
		fi

		systemctl enable --now nordvpnd

		# Set nordvpn prefs
		runuser -l "$NAME" -c "
			nordvpn set technology openvpn
			nordvpn set protocol tcp
			nordvpn set dns 9.9.9.9 149.112.112.112
			nordvpn set analytics off
		"
	fi
}

dnf_security
firewalld_config
firejail_config
nordvpn_config

#================================================
#    SETUP USER DIRECTORY
#================================================

copy_dotfiles() {
	echo -e "\nCopying dotfiles ..."

	# Set username while copying
	if [[ -d ${DIR}/dotfiles ]]; then
		find "${DIR}"/dotfiles -type f | while read -r file; do
			dest="/home/${NAME}/${file#${DIR}/dotfiles/}"
			mkdir -p "$(dirname "$dest")"
			sed -e "s|<user>|${NAME}|" "$file" > "$dest"
		done
	fi
}

set_permissions() {
	echo -e "\nSetting $HOME permissions ..."

	mkdir -p /home/"${NAME}"/{Documents,Downloads,Projects}

	chown -R "${NAME}":"${NAME}" /home/"${NAME}"
	chmod -R 0750 /home/"${NAME}"
}

disable_recents() {
	echo -e "\nDisabling recent files ..."

	local recent="/home/$(logname)/.local/share/recently-used.xbel"

	# Clear and make immutable
	truncate -s 0 "$recent"
	chattr +i "$recent" 2>/dev/null || true
}

harden_firefox() {
	echo -e "\nHardening Firefox ..."

	firefox_dirs=("/usr/lib64/firefox" "/opt/firefox-esr")

	# Remove telemetry features
	for dir in "${firefox_dirs[@]}"; do
		for f in crashreporter pingsender; do
			[[ -f ${dir}/${f} ]] && rm -f "${dir}"/"${f}"
		done
	done
}

copy_dotfiles
set_permissions
disable_recents
harden_firefox

#================================================
#    SETUP COMPLETE
#================================================

clear
echo -e "\n Setup complete!\n\n Press any key to reboot..."
read -n 1 -rs

# Clean up
rm -rf ../*minimal*/ ../*main.zip

reboot
