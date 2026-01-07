# ~/.bash_aliases

alias sano='sudo -B nano'
alias sedit='sudo xdg-open'
alias upd='sudo dnf -y update'
alias get='sudo dnf install --setopt=install_weak_deps=False'
alias rem='sudo dnf remove'
alias scurl='curl --tlsv1.3 --proto =https -LO'
alias difs='diff -r --side-by-side --color'
alias ll='ls -la'
alias dl='cd ~/Downloads'
alias pro='cd ~/Projects'
alias ..='cd ..'
alias ...='cd ../..'

alias vpnc='nordvpn c'
alias vpnd='nordvpn d'
alias vpns='nordvpn status'
