#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Ripristino COSMIC su Pop!_OS 24.04 + driver NVIDIA corretti
# Testato per upgrade 22.04 -> 24.04 con GTX 980 (Maxwell)
# ------------------------------------------------------------

# Opzioni
USE_COSMIC_GREETER=false
RESET_GNOME=false
SET_DEFAULT_SESSION=false

for arg in "$@"; do
  case "$arg" in
    --use-cosmic-greeter) USE_COSMIC_GREETER=true ;;
    --reset-gnome)        RESET_GNOME=true ;;
    --set-default-session) SET_DEFAULT_SESSION=true ;;
    -h|--help)
      cat <<'EOF'
Uso: ./fix-pop24-cosmic.sh [opzioni]

Opzioni:
  --reset-gnome         Esegue backup e reset delle personalizzazioni GNOME dell'utente
  --use-cosmic-greeter  Imposta COSMIC Greeter come display manager (al posto di GDM)
  --set-default-session Imposta "COSMIC" come sessione predefinita per l'utente corrente
  -h, --help            Mostra questo aiuto
EOF
      exit 0
      ;;
    *)
      echo "Opzione non riconosciuta: $arg" >&2
      exit 2
      ;;
  esac
done

if [[ $EUID -eq 0 ]]; then
  echo "Per sicurezza, esegui questo script come utente normale (non root)."
  exit 1
fi

TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

echo "Utente di destinazione: $TARGET_USER"
sleep 1

# ----------------------------------------------------------------
# 1) Aggiorna indici e reinstalla i componenti principali COSMIC
# ----------------------------------------------------------------
echo -e "\n[1/6] Reinstallo pacchetti chiave del desktop COSMIC..."
sudo apt update -y

COSMIC_PKGS=(
  cosmic-session cosmic-comp cosmic-settings cosmic-settings-daemon
  cosmic-panel cosmic-launcher cosmic-applets
  cosmic-greeter cosmic-store cosmic-files cosmic-term
  xdg-desktop-portal-cosmic pop-launcher
)

# --reinstall per riparare eventuali file corrotti/mancanti
sudo apt install --reinstall -y "${COSMIC_PKGS[@]}"

# ----------------------------------------------------------------
# 2) Imposta (opzionale) la sessione COSMIC come predefinita
#    via AccountsService (GDM/COSMIC la rispetta)
# ----------------------------------------------------------------
if [[ "$SET_DEFAULT_SESSION" == true ]]; then
  echo -e "\n[2/6] Imposto COSMIC come sessione predefinita per $TARGET_USER..."
  ACCOUNTS_DIR="/var/lib/AccountsService/users"
  TMPFILE="$(mktemp)"
  sudo install -d -m 0755 "$ACCOUNTS_DIR"
  USERFILE="$ACCOUNTS_DIR/$TARGET_USER"

  if [[ -f "$USERFILE" ]]; then
    sudo cp -a "$USERFILE" "${USERFILE}.bak.$(date +%F-%H%M%S)"
  fi

  # XSession=cosmic è il nome registrato dalla cosmic-session
  # (il selettore di sessione mostrerà "COSMIC")
  {
    echo "[User]"
    echo "XSession=cosmic"
    echo "SystemAccount=false"
  } > "$TMPFILE"

  sudo mv "$TMPFILE" "$USERFILE"
  sudo chown root:root "$USERFILE"
  sudo chmod 0644 "$USERFILE"
fi

# ----------------------------------------------------------------
# 3) Driver NVIDIA: preferisci ramo 580 (supporta Maxwell)
#    - prova driver raccomandato; se disponibile 580, forzalo
# ----------------------------------------------------------------
echo -e "\n[3/6] Verifico e installo driver NVIDIA più adatti..."
if ! command -v ubuntu-drivers >/dev/null 2>&1; then
  sudo apt install -y ubuntu-drivers-common
fi

AVAILABLE="$(ubuntu-drivers list || true)"
echo "$AVAILABLE"

if echo "$AVAILABLE" | grep -qE 'nvidia-driver-580(\b|-server|-open)?'; then
  echo "Trovato driver 580: installo nvidia:580"
  sudo ubuntu-drivers install nvidia:580 || true
else
  echo "Driver 580 non elencato: installo driver raccomandato."
  sudo ubuntu-drivers install || true
fi

# ----------------------------------------------------------------
# 4) (Opzionale) Passa al COSMIC Greeter come display manager
# ----------------------------------------------------------------
if [[ "$USE_COSMIC_GREETER" == true ]]; then
  echo -e "\n[4/6] Abilito COSMIC Greeter (display manager)..."
  # Se i servizi non esistono, il comando non fallisce grazie a '|| true'
  sudo systemctl enable cosmic-greeter.service cosmic-greeter-daemon.service || true
  # Disabilita GDM solo se i servizi COSMIC esistono
  if systemctl list-unit-files | grep -q cosmic-greeter.service; then
    sudo systemctl disable gdm.service gdm3.service 2>/dev/null || true
  fi
fi

# ----------------------------------------------------------------
# 5) (Opzionale) Reset sicuro delle personalizzazioni GNOME utente
# ----------------------------------------------------------------
if [[ "$RESET_GNOME" == true ]]; then
  echo -e "\n[5/6] Eseguo backup + reset configurazioni GNOME dell'utente..."
  TS="$(date +%F-%H%M%S)"
  # Backup dconf
  sudo -u "$TARGET_USER" sh -c "dconf dump / > \"$TARGET_HOME/dconf-backup-$TS.txt\" || true"
  # Rinominare cartelle note senza distruggere dati
  for p in ".local/share/gnome-shell" ".config/gnome"; do
    if [[ -d "$TARGET_HOME/$p" ]]; then
      mv "$TARGET_HOME/$p" "$TARGET_HOME/${p}.bak.$TS"
    fi
  done
  # Reset chiavi GNOME solo se disponibili
  sudo -u "$TARGET_USER" sh -c "command -v dconf >/dev/null && dconf reset -f /org/gnome/ || true"
fi

# ----------------------------------------------------------------
# 6) Informazioni finali e riavvio suggerito
# ----------------------------------------------------------------
echo -e "\n[6/6] Operazioni completate."
echo "Suggerimenti:"
echo " - Riavvia ora: sudo reboot"
echo " - Alla schermata di login, se necessario, clicca l'INGRANAGGIO e scegli 'COSMIC'."
echo " - Verifica in sessione:"
echo "     echo \$XDG_SESSION_TYPE       # atteso: wayland"
echo "     echo \$XDG_CURRENT_DESKTOP    # atteso: COSMIC"
