# Installed to /etc/profile.d/haar-remind.sh — reminds operator to run the wizard or check FOG install.
if [[ -n "${PS1:-}" ]] && [[ "$(id -u)" -ne 0 ]]; then
  if [[ ! -f /etc/haar/wizard.done ]]; then
    echo ""
    echo "  [Brume] First-time setup: run  sudo haar-install-wizard"
    echo ""
  elif [[ ! -f /etc/haar/fog-native.done ]]; then
    echo ""
    echo "  [Brume] Native FOG install may still be running; check: journalctl -fu haar-fog-install.service"
    echo ""
  fi
fi
