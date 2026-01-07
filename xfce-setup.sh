#!/usr/bin/env bash

#  xfce-setup.sh
#
#  A simple bash script to set up a Fedora Xfce Minimal workstation
#
#  Repo: github.com/kuladog/fedora-xfce-minimal
#  Revised: 2026-01-01
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
	  echo -e "\n Run the script as root.\n"
	  exit 1
	fi
}

confirm_prompt() {
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
confirm_prompt

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

	pkgs=("${GROUP_PACKAGES[@]}" "${XFCE_PACKAGES[@]}" "${ADDON_PACKAGES[@]}")

	dnf install -y --skip-unavailable --allowerasing "${pkgs[@]}"

	# Check if running in VM
	if [[ $(systemd-detect-virt) != none ]]; then
		echo -e "\nInstalling guest agents ..."
		dnf install -y @guest-desktop-agents
	fi
}

install_theme() {
	local theme_dir="/home/${NAME}/.themes"

	curl -LO https://github.com/kuladog/adwaita-grey-dark/archive/refs/heads/main.zip

	if [[ -f ${DIR}/main.zip ]]; then
		echo -e "\nInstalling desktop theme ..."

		mkdir -p "$theme_dir"

		unzip -q main.zip
		mv ./*grey-dark* "${theme_dir}"/Adwaita-grey-dark
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

config_files() {
	echo -e "\nCopying configuration files ..."

	# Set user, host and copy
	if [[ -d ${DIR}/configs ]]; then
		find "${DIR}"/configs -type f | while read -r file; do
			dest="/etc/${file#${DIR}/configs/}"
			mkdir -p "$(dirname "$dest")"
			sed -e "s|<user>|${NAME}|" -e "s|<host>|${HOST}|" "$file" > "$dest"
		done
	fi
}

config_permissions() {
	echo -e "\nSetting file permissions ..."

	# Post-copy sanity check
	find /etc/systemd -type d -exec chmod 0755 {} +
	find /etc/systemd -type f -exec chmod 0644 {} +

	find /etc/cron.*/ -type d -exec chmod 0640 {} +

	for file in /etc/{crontab,cron.*,at.*,ssh/sshd_config}; do
		[[ -f $file ]] && chmod 0600 "$file"
	done

	for file in /etc/{sudoers,sudoers.d/*}; do
		[[ -f $file ]] && chmod 0440 "$file"
	done

	for file in /etc/{shadow,gshadow}; do
		[[ -f $file ]] && chmod 0400 "$file"
	done
}

config_grub() {
	echo -e "\nUpdating GRUB configuration ..."

	# Rebuild the grub.cfg
	if ! grub2-mkconfig -o /boot/grub2/grub.cfg; then
		echo -e "\n ERROR: Grub could not be configured."
		exit 1
	fi
}

config_mountpoints() {
    echo -e "\nHardening mount points ..."

	local fstable="/etc/fstab"

	# Backup fstab and edit in place
	if [[ -w $fstable ]]; then
		sed -i.bak \
		-e '/boot/ s=relatime=noatime=' \
		-e '/\/[[:space:]]/ s=relatime=noatime=' \
		-e '/home\|var/ s=defaults=noatime,nodev,nosuid=' \
		-e 's/\S\+/0/5' \
		-e 's/\S\+/0/6' \
		"$fstable"

		{
		echo "tmpfs /tmp        tmpfs   noatime,nodev,nosuid,noexec 0 0"
		echo "tmpfs /var/tmp    tmpfs   noatime,nodev,nosuid,noexec 0 0"
		echo "tmpfs /dev/shm    tmpfs   noatime,nodev,nosuid,noexec 0 0"
		} >> "$fstable"

		chmod 1777 /tmp /var/tmp /dev/shm
	fi
}

config_lightdm() {
	echo -e "\nConfiguring display manager ..."

	# Warn if not installed
	if command -v lightdm &>/dev/null; then
		systemctl enable lightdm
		systemctl set-default graphical.target
	else
		echo "WARNING: LightDM is not installed."
	fi
}

config_libvirt() {
	# Add user to group
	if command -v libvirtd &>/dev/null; then
		echo -e "\nConfiguring virt-manager ..."

		usermod -aG libvirt "$NAME"
	fi
}

config_files
config_permissions
config_grub
config_mountpoints
config_lightdm
config_libvirt

#================================================
#    SYSTEM SECURITY
#================================================

security_dnf() {
	# Enable if installed
	if command -v dnf-automatic &>/dev/null; then
		echo -e "\nEnabling DNF security updates ..."

		systemctl enable --now dnf-automatic.timer
	fi
}

security_firewall() {
	ruleset=(
		--set-default-zone=drop
		--add-service=https
		--add-icmp-block-inversion
		--add-rich-rule='rule family="ipv6" source address="::/0" reject'
		)

	if command -v firewalld &>/dev/null; then
		echo -e "\nConfiguring Firewalld ..."

		# Set firewall defaults
		for rule in "${ruleset[@]}"; do
			firewall-cmd "$rule"
		done
	fi
}

security_firejail() {
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

security_nordvpn() {
	if command -v nordvpn &>/dev/null; then
		echo -e "\nConfiguring NordVPN ..."

		# Add user to nordvpn group
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

security_dnf
security_firewall
security_firejail
security_nordvpn

#================================================
#    SETUP USER DIRECTORY
#================================================

user_dotfiles() {
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

user_permissions() {
	echo -e "\nSetting ${NAME} permissions ..."

	mkdir -p /home/"${NAME}"/{Documents,Downloads,Projects}

	chown -R "${NAME}":"${NAME}" /home/"${NAME}"
	chmod -R 0750 /home/"${NAME}"
}

user_no_recents() {
	echo -e "\nDisabling recent files ..."

	local recents_dir="/home/$(logname)/.local/share/recently-used.xbel"

	# Clear and make immutable
	truncate -s 0 "$recents_dir"
	chattr +i "$recents_dir" 2>/dev/null || true
}

user_firefox() {
	echo -e "\nHardening Firefox ..."

	firefox_dirs=(/usr/lib{,64}/firefox /opt/firefox{,-esr})

	# Remove telemetry features
	for dir in "${firefox_dirs[@]}"; do
		[[ -d $dir ]] || continue
		for f in crashreporter pingsender; do
			rm -f "${dir}/${f}"
		done
	done
}

user_dotfiles
user_permissions
user_no_recents
user_firefox

#================================================
#    SETUP COMPLETE
#================================================

clear
echo -e "\n Setup complete!\n\n Press any key to reboot..."
read -n 1 -rs

# Clean up
rm -rf ../*minimal*/ ../*main.zip

reboot
