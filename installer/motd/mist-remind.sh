# Installed to /etc/profile.d/mist-remind.sh — reminds operator to run the wizard or check FOG install.
if [[ -n "${PS1:-}" ]] && [[ "$(id -u)" -ne 0 ]]; then
  if [[ ! -f /etc/mist/wizard.done ]]; then
    echo ""
    echo "  [Brume] First-time setup: run  sudo mist-install-wizard"
    echo ""
  elif [[ ! -f /etc/mist/fog-native.done ]]; then
    echo ""
    echo "  [Brume] Native FOG install may still be running; check: journalctl -fu mist-fog-install.service"
    echo ""
  fi
fi
