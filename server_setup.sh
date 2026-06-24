#!/bin/bash
# =============================================================================
#  Script di configurazione iniziale per un server Ubuntu (22.04 / 24.04 / 26.04)
#
#  Cosa fa, in breve: aggiorna il sistema, installa un set di pacchetti utili,
#  configura swap, firewall, aggiornamenti automatici, mette in sicurezza SSH,
#  crea utenti da un file YAML, installa Docker e applica qualche ottimizzazione
#  di rete. Opzionalmente (con -T) abilita lo sblocco automatico del disco
#  cifrato tramite il chip TPM, cosi' al boot non serve digitare la passphrase.
#
#  Va eseguito come root su una macchina appena installata.
# =============================================================================

# Lo script modifica file di sistema: senza permessi di root non andrebbe da
# nessuna parte, quindi conviene fermarsi subito con un messaggio chiaro.
if [ "$(id -u)" -ne 0 ]; then
    echo "Questo script deve essere eseguito come root" >&2
    exit 1
fi

# set -e: esci al primo comando che fallisce (niente disastri a meta' strada).
# set -u: errore se usi una variabile mai definita (scova i typo).
# pipefail: una pipe fallisce se fallisce un qualsiasi comando al suo interno.
set -euo pipefail

# Messaggio di aiuto con l'elenco delle opzioni disponibili.
usage() {
    echo "Uso: $0 [-h] [-s swap_size] [-d] [-u] [-n] [-t timezone] [-l locale] [-c users_config] [-q] [-k livepatch_token] [-f] [-T] [-P pcrs] [-F]"
    echo "Opzioni:"
    echo "  -h          Mostra questo messaggio"
    echo "  -s size     Dimensione dello swap in GB (default: 8)"
    echo "  -d          Non installare Docker"
    echo "  -u          Non configurare gli aggiornamenti automatici"
    echo "  -n          Modalita' non interattiva (nessuna domanda)"
    echo "  -t timezone Imposta il fuso orario (default: Europe/Rome)"
    echo "  -l locale   Imposta la lingua di sistema (default: en_US.UTF-8)"
    echo "  -c config   Percorso del file YAML con gli utenti da creare"
    echo "  -q          Installa il QEMU guest agent (utile nelle VM)"
    echo "  -k token    Token Canonical Livepatch (opzionale)"
    echo "  -f          Non configurare il firewall UFW"
    echo "  -T          Abilita lo sblocco automatico del disco LUKS via TPM"
    echo "  -P pcrs     PCR del TPM a cui legare la chiave (default: 7)"
    echo "  -F          Forza il setup TPM anche con Secure Boot disattivato"
    exit 1
}

# Valori di default: vengono sovrascritti dalle opzioni passate a riga di comando.
SWAP_SIZE=8
SKIP_DOCKER=false
SKIP_UPGRADES=false
SKIP_UFW=false
NON_INTERACTIVE=false
TIMEZONE="Europe/Rome"
LOCALE="en_US.UTF-8"
USERS_CONFIG=""
INSTALL_QEMU=false
LIVEPATCH_TOKEN=""
SETUP_TPM=false
TPM_PCRS="7"           # PCR 7 = stato Secure Boot. E' il piu' stabile: non cambia
                       # quando aggiorni il kernel, quindi lo sblocco non si rompe.
TPM_FORCE_NO_SB=false

# Lettura delle opzioni. La stringa dopo getopts elenca le lettere accettate;
# i due punti dopo una lettera (es. s:) significano "questa opzione vuole un valore".
while getopts "hs:dunt:l:c:qk:fTP:F" opt; do
    case $opt in
        h) usage ;;
        s)
            # Lo swap dev'essere un numero non negativo, altrimenti ci fermiamo.
            if ! [[ "$OPTARG" =~ ^[0-9]+$ ]] || [ "$OPTARG" -lt 0 ]; then
                echo "Errore: la dimensione dello swap deve essere un numero non negativo"
                exit 1
            fi
            SWAP_SIZE=$OPTARG
            ;;
        d) SKIP_DOCKER=true ;;
        u) SKIP_UPGRADES=true ;;
        n) NON_INTERACTIVE=true ;;
        t) TIMEZONE="$OPTARG" ;;
        l) LOCALE="$OPTARG" ;;
        c) USERS_CONFIG="$OPTARG" ;;
        q) INSTALL_QEMU=true ;;
        k) LIVEPATCH_TOKEN="$OPTARG" ;;
        f) SKIP_UFW=true ;;
        T) SETUP_TPM=true ;;
        P) TPM_PCRS="$OPTARG" ;;
        F) TPM_FORCE_NO_SB=true ;;
        \?)
            echo "Opzione non valida: -$OPTARG" >&2
            usage
            ;;
    esac
done

shift $((OPTIND-1))

# Stampa un messaggio con data e ora davanti: comodo per seguire cosa succede
# e per ritrovare le cose nei log.
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Logga un errore ed esce. Da usare quando il problema e' irrecuperabile.
handle_error() {
    log "Errore: $1"
    exit 1
}

# Funzione che esegue un comando e ne gestisce l'esito in modo uniforme.
# - Usa "bash -lc" (login shell) cosi' i percorsi di apt/ufw/systemctl ecc.
#   funzionano in modo coerente: piu' affidabile di eval per l'automazione.
# - Il secondo parametro decide se un errore e' fatale (default: si').
#   Passando "false" il fallimento diventa solo un avviso e lo script prosegue,
#   utile per comandi che possono "non riuscire" senza che sia un dramma.
execute() {
    local cmd="$1"
    local fatal="${2:-true}"

    log "Eseguo: $cmd"
    if ! bash -lc "$cmd"; then
        if [ "$fatal" = "true" ]; then
            handle_error "Comando fallito: $cmd"
        else
            log "Avviso: comando fallito (proseguo): $cmd"
        fi
        return 1
    fi
    return 0
}

# Installa la versione "giusta" di yq. Attenzione: esistono due programmi che
# si chiamano yq con sintassi diverse. Quello che a volte arriva da apt NON e'
# compatibile con le query usate piu' avanti (.users[...]): per evitare errori
# scarichiamo direttamente il binario del progetto di Mike Farah.
install_yq() {
    if command -v yq >/dev/null 2>&1 && yq --version 2>/dev/null | grep -qi "mikefarah"; then
        log "yq (mikefarah) gia' presente."
        return 0
    fi
    log "Installo yq (versione mikefarah)..."
    local arch
    arch=$(dpkg --print-architecture)
    execute "wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch}"
    execute "chmod +x /usr/local/bin/yq"
}

log "Avvio configurazione del server..."
execute "apt update"
install_yq

# Riepilogo di cosa stiamo per fare, in base alle opzioni scelte.
log "Configurazione:"
log "- Swap: ${SWAP_SIZE}GB"
log "- Docker: $([ "$SKIP_DOCKER" = true ] && echo "Salta" || echo "Installa")"
log "- Aggiornamenti automatici: $([ "$SKIP_UPGRADES" = true ] && echo "Salta" || echo "Configura")"
log "- Interattivo: $([ "$NON_INTERACTIVE" = true ] && echo "No" || echo "Si")"
log "- Fuso orario: $TIMEZONE"
log "- Lingua: $LOCALE"
log "- QEMU guest agent: $([ "$INSTALL_QEMU" = true ] && echo "Installa" || echo "Salta")"
log "- Firewall UFW: $([ "$SKIP_UFW" = true ] && echo "Salta" || echo "Configura")"
log "- Sblocco TPM del disco: $([ "$SETUP_TPM" = true ] && echo "Configura (PCR $TPM_PCRS)" || echo "Salta")"

# Se e' stato indicato un file utenti, mostriamo in anteprima chi verra' creato,
# cosi' chi lancia lo script puo' controllare prima di confermare.
if [ -n "$USERS_CONFIG" ]; then
    log "Utenti che verranno creati:"
    user_count=$(yq '.users | length' "$USERS_CONFIG")
    if [ $? -ne 0 ] || [ -z "$user_count" ] || [ "$user_count" = "null" ]; then
        handle_error "Impossibile leggere il numero di utenti dal file di configurazione"
    fi
    for i in $(seq 0 $((user_count - 1))); do
        username=$(yq ".users[$i].username" "$USERS_CONFIG" | tr -d '"')
        fullname=$(yq ".users[$i].full_name // \"<nessun nome>\"" "$USERS_CONFIG" | tr -d '"')
        groups=$(yq ".users[$i].groups[]" "$USERS_CONFIG" | tr -d '"')
        github=$(yq ".users[$i].ssh.github_username // \"<nessun github>\"" "$USERS_CONFIG" | tr -d '"')
        log "  * $username (${fullname})"
        log "    - Gruppi: ${groups:-<nessuno>}"
        log "    - GitHub: $github"
    done
fi

# Ultima conferma prima di iniziare a modificare il sistema (saltata con -n).
if [ "$NON_INTERACTIVE" = false ]; then
    echo
    read -p "Vuoi procedere con l'installazione? [Y/n] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        log "Installazione annullata dall'utente"
        exit 1
    fi
fi

# Aggiornamento completo del sistema.
log "Aggiorno i pacchetti di sistema..."
execute "apt update && apt dist-upgrade -y"

# Il pacchetto 'locales' deve esserci PRIMA di generare/impostare la lingua,
# altrimenti locale-gen non avrebbe nulla con cui lavorare.
log "Installo il supporto per le lingue (locales)..."
execute "apt install -y locales"

# Fuso orario e lingua di sistema.
log "Configuro fuso orario e lingua..."
if [ -n "$TIMEZONE" ]; then
    execute "timedatectl set-timezone $TIMEZONE"
fi

if [ -n "$LOCALE" ]; then
    execute "locale-gen $LOCALE"
    execute "update-locale LANG=$LOCALE"
fi

# Set di pacchetti di base: strumenti da riga di comando, utilita' di rete,
# sicurezza (fail2ban, ufw) e qualche comodita'. Su Ubuntu recenti 'chrony'
# sostituisce il vecchio 'ntp' per la sincronizzazione dell'orario.
log "Installo i pacchetti di base..."
PACKAGES=(
    zsh
    fail2ban
    ufw
    fonts-powerline
    ca-certificates
    curl
    gnupg-agent
    software-properties-common
    net-tools
    traceroute
    iperf
    git
    build-essential
    gnupg
    lsb-release
    locales
    chrony
    nano
    micro
    wget
    git-lfs
    fzf
    cifs-utils
    nfs-common
    htop
    ncdu
    ssh-import-id
)

# Pacchetti aggiunti solo se servono, in base alle opzioni.
[ "$SKIP_UPGRADES" = false ] && PACKAGES+=(unattended-upgrades)
[ "$INSTALL_QEMU" = true ] && PACKAGES+=(qemu-guest-agent)

execute "apt install -y ${PACKAGES[*]}"

# Il guest agent permette all'host (es. Proxmox/libvirt) di comunicare con la VM:
# spegnimento pulito, lettura dell'IP, ecc. Ha senso solo dentro una macchina virtuale.
if [ "$INSTALL_QEMU" = true ]; then
    log "Configuro il QEMU guest agent..."
    execute "systemctl start qemu-guest-agent"
    execute "systemctl enable qemu-guest-agent"
fi

# Livepatch applica le patch di sicurezza al kernel senza riavviare. Si attiva
# solo se viene fornito un token Canonical, altrimenti si salta.
if [ -n "$LIVEPATCH_TOKEN" ]; then
    log "Configuro Canonical Livepatch..."
    execute "snap install canonical-livepatch"
    execute "pro attach $LIVEPATCH_TOKEN" false
    execute "canonical-livepatch status --verbose" false
else
    log "Salto Canonical Livepatch (nessun token fornito)"
fi

# Imposta nano come editor predefinito (piu' amichevole di vi per molti).
log "Imposto nano come editor predefinito..."
execute "update-alternatives --install /usr/bin/editor editor /usr/bin/nano 100" false
execute "update-alternatives --set editor /usr/bin/nano" false

# Aggiornamenti automatici di sicurezza.
if [ "$SKIP_UPGRADES" = false ]; then
    log "Configuro gli aggiornamenti automatici..."
    if [ "$NON_INTERACTIVE" = true ]; then
        execute "dpkg-reconfigure --priority=medium -f noninteractive unattended-upgrades"
    else
        execute "dpkg-reconfigure --priority=medium unattended-upgrades"

        # Suggerimenti da applicare a mano nel file che stiamo per aprire.
        log "Apro il file di configurazione di unattended-upgrades..."
        log "Modifiche consigliate:"
        log "1. Togli il commento a '\${distro_id}:\${distro_codename}-updates' per gli aggiornamenti non di sicurezza"
        log "2. Imposta 'Unattended-Upgrade::AutoFixInterruptedDpkg' a 'true'"
        log "3. Imposta 'Unattended-Upgrade::MinimalSteps' a 'true'"
        log "4. Abilita la pulizia automatica (Remove-Unused-Dependencies, ecc.)"
        log "5. Configura il riavvio automatico secondo le tue esigenze"
        echo "Premi un tasto per continuare..."
        read -n 1 -s
        execute "nano /etc/apt/apt.conf.d/50unattended-upgrades"
    fi

    # Pianifica controllo, download e installazione automatica degli aggiornamenti.
    log "Imposto la pianificazione degli aggiornamenti automatici..."
    execute "cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists \"1\";
APT::Periodic::Download-Upgradeable-Packages \"1\";
APT::Periodic::Unattended-Upgrade \"1\";
APT::Periodic::AutocleanInterval \"7\";
EOF"
fi

# Creazione dello swap (memoria di scambio su disco). Se -s 0, si salta del tutto.
if [ "$SWAP_SIZE" -gt 0 ]; then
    log "Configuro lo swap (${SWAP_SIZE}GB)..."

    # Rimuoviamo eventuali file di swap preesistenti per evitare doppioni.
    # swapoff e' non-fatale: un file di swap rimasto a meta' da un run precedente
    # non e' uno swap attivo valido, quindi swapoff fallirebbe; in quel caso
    # vogliamo comunque proseguire e rimuoverlo.
    if [ -f /swapfile ]; then
        execute "swapoff /swapfile" false
        execute "rm -f /swapfile" false
    fi
    if [ -f /swap.img ]; then
        execute "swapoff /swap.img" false
        execute "rm -f /swap.img" false
    fi

    # Controlliamo lo spazio libero prima di creare il file di swap. Su dischi
    # piccoli un valore troppo alto farebbe fallire fallocate e, con set -e,
    # bloccherebbe l'intero script: meglio avvisare e saltare lo swap.
    avail_mb=$(df --output=avail -m / 2>/dev/null | tail -n1 | tr -d ' ')
    needed_mb=$((SWAP_SIZE * 1024))
    if [ -n "$avail_mb" ] && [ "$avail_mb" -lt "$((needed_mb + 512))" ]; then
        log "Attenzione: spazio insufficiente per uno swap da ${SWAP_SIZE}GB"
        log "  (liberi ~${avail_mb}MB, servono ~${needed_mb}MB). Salto lo swap."
        log "  Usa -s con un valore piu' piccolo se vuoi comunque lo swap."
    else
        # Crea il file, lo protegge, lo formatta come swap e lo attiva.
        execute "fallocate -l ${SWAP_SIZE}G /swap.img"
        execute "chmod 600 /swap.img"
        execute "mkswap /swap.img"
        execute "swapon /swap.img"

        # Lo aggiunge a fstab cosi' resta attivo dopo il riavvio.
        if ! grep -q "/swap.img" /etc/fstab; then
            execute "echo '/swap.img none swap sw 0 0' >> /etc/fstab"
        fi

        # swappiness basso = usa lo swap solo quando serve (meglio sui server).
        # Scriviamo in /etc/sysctl.d/ (non in /etc/sysctl.conf): su Ubuntu recenti
        # le impostazioni vengono applicate al boot da /etc/sysctl.d/*.conf, mentre
        # /etc/sysctl.conf puo' non essere processato, e il valore non persisterebbe.
        execute "sysctl vm.swappiness=10"
        execute "sysctl vm.vfs_cache_pressure=50"
        execute "cat > /etc/sysctl.d/98-swap-tune.conf << 'EOF'
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF"
    fi
else
    log "Salto la configurazione dello swap (dimensione 0)"
fi

# Firewall UFW: permette SSH e blocca il resto.
if [ "$SKIP_UFW" = false ]; then
    log "Configuro il firewall UFW..."
    execute "ufw allow OpenSSH"
    # 'deny routed' = di default non inoltra traffico tra reti diverse. E' la
    # scelta piu' prudente; Docker gestira' da solo le regole per i suoi container.
    execute "ufw default deny routed"
    if [ "$NON_INTERACTIVE" = true ]; then
        execute "ufw --force enable"
    else
        execute "ufw enable"
    fi
else
    log "Salto la configurazione del firewall UFW"
fi

# -----------------------------------------------------------------------------
# Messa in sicurezza di SSH
# -----------------------------------------------------------------------------
# Scriviamo le impostazioni in un file dentro sshd_config.d/ invece di modificare
# direttamente sshd_config con dei sed. Motivo: su Ubuntu recenti il file
# principale include altri file (es. quelli di cloud-init) che verrebbero applicati
# DOPO le nostre modifiche, vanificandole. Un nostro file con numero alto (99) ha
# la precedenza e non rischia di essere sovrascritto.
log "Metto in sicurezza la configurazione SSH..."
execute "cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak"
execute "mkdir -p /etc/ssh/sshd_config.d"
execute "cat > /etc/ssh/sshd_config.d/00-hardening.conf << 'EOF'
PasswordAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
MaxAuthTries 3
PermitEmptyPasswords no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF"

# Prima di riavviare SSH controlliamo che la configurazione sia valida. Questo
# passaggio e' importante: abbiamo appena disattivato l'accesso con password,
# quindi se la config fosse rotta e SSH non ripartisse rischieremmo di restare
# chiusi fuori dal server. Se non e' valida, ripristiniamo il backup e usciamo.
log "Verifico la configurazione SSH..."
if ! execute "sshd -t" false; then
    log "Errore: configurazione SSH non valida, ripristino il backup..."
    execute "rm -f /etc/ssh/sshd_config.d/00-hardening.conf" false
    execute "cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config" false
    handle_error "La validazione della configurazione SSH e' fallita"
fi

log "Riavvio il servizio SSH..."
execute "systemctl restart ssh"

# -----------------------------------------------------------------------------
# Sblocco automatico del disco cifrato (LUKS) tramite TPM, usando dracut.
# -----------------------------------------------------------------------------
# Idea di fondo: se il disco e' cifrato con LUKS, normalmente al boot devi
# digitare una passphrase. Il TPM (un piccolo chip di sicurezza, emulato nelle
# VM come "vTPM") puo' custodire una chiave e rilasciarla automaticamente, ma
# SOLO se il sistema si avvia in uno stato attendibile (misurato nei "PCR").
# Cosi' il disco si sblocca da solo, ma se qualcuno manomette il boot il TPM si
# rifiuta e si torna a chiedere la passphrase.
#
# Nota tecnica importante: su Ubuntu il sistema initramfs predefinito non sa
# usare le chiavi messe nel TPM da systemd-cryptenroll. Per questo passiamo a
# "dracut", che invece le supporta.

# Crea un piccolo script di comodo per rifare l'enroll in futuro. Servira':
# il valore dei PCR cambia dopo un aggiornamento del firmware/BIOS o se attivi/
# disattivi Secure Boot, e quando succede lo sblocco automatico smette di
# funzionare finche' non si "ri-registra" la chiave. Con questo helper basta
# un comando solo invece di ricordarsi tutta la procedura.
_install_tpm_reenroll_helper() {
    local dev="$1"
    local pcrs="$2"
    local helper="/usr/local/sbin/tpm-reenroll"
    cat > "$helper" << EOF
#!/bin/bash
# Ri-registra la chiave TPM2 sul disco LUKS. Da usare dopo aggiornamenti del
# firmware/BIOS oppure dopo aver attivato/disattivato Secure Boot.
set -euo pipefail
if [ "\$(id -u)" -ne 0 ]; then echo "Esegui come root"; exit 1; fi
LUKS_DEV="${dev}"
PCRS="${pcrs}"
echo "Ri-registro TPM2 su \$LUKS_DEV (PCR: \$PCRS)"
systemd-cryptenroll --wipe-slot=tpm2 "\$LUKS_DEV" || true
systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs="\$PCRS" "\$LUKS_DEV"
dracut --force --regenerate-all
update-grub || true
echo "Fatto. Riavvia in modo controllato per verificare lo sblocco."
EOF
    chmod 700 "$helper" 2>/dev/null || true
    log "Helper per la ri-registrazione installato: $helper (uso: sudo tpm-reenroll)"
}

setup_tpm_luks() {
    log "=== Sblocco automatico TPM per LUKS (dracut): avvio ==="

    # Una serie di controlli preliminari. Ognuno, se non e' soddisfatto, fa
    # uscire la funzione SENZA far fallire l'intero script: cosi' lo stesso
    # script gira tranquillo anche su macchine dove il TPM non c'entra nulla.

    # Servono questi comandi; su immagini molto minimali potrebbero mancare.
    local missing=""
    for cmd in blkid systemd-cryptenroll; do
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done
    if [ -n "$missing" ]; then
        log "Avviso: comandi mancanti:$missing. Salto il setup TPM."
        return 0
    fi

    # La registrazione chiede la passphrase LUKS attuale: serve qualcuno che la
    # digiti, quindi in modalita' non interattiva non ha senso e si salta.
    if [ "$NON_INTERACTIVE" = true ]; then
        log "Avviso: il setup TPM richiede la passphrase (interattivo). Salto."
        return 0
    fi

    # Secure Boot esiste solo in modalita' UEFI. Se siamo in BIOS legacy, legare
    # la chiave al PCR del Secure Boot non avrebbe senso.
    if [ ! -d /sys/firmware/efi ]; then
        log "Avviso: avvio non-UEFI (BIOS legacy). Salto il setup TPM."
        return 0
    fi

    # Serve un TPM. Nelle VM va aggiunto come "vTPM 2.0" dall'host; se manca,
    # questi file non esistono e ci fermiamo qui.
    if [ ! -e /dev/tpm0 ] && [ ! -e /dev/tpmrm0 ]; then
        log "Avviso: nessun TPM (/dev/tpm0). Nelle VM aggiungi un vTPM 2.0. Salto."
        return 0
    fi

    # Cerchiamo la partizione cifrata vera e propria (quella di tipo crypto_LUKS),
    # non il "mapper" gia' aperto: systemd-cryptenroll vuole il disco di partenza.
    local luks_dev
    luks_dev=$(blkid -o device --match-token TYPE=crypto_LUKS 2>/dev/null | head -n1)
    if [ -z "$luks_dev" ]; then
        log "Avviso: nessuna partizione LUKS trovata. Niente da sbloccare. Salto."
        return 0
    fi
    log "Partizione LUKS trovata: $luks_dev"

    # Ubuntu 26.04+ puo' gestire la cifratura TPM gia' dall'installer ("hardware-
    # backed encryption"). Se rileviamo che lo sblocco TPM e' gia' attivo E che
    # il sistema usa gia' il meccanismo nativo (systemd-cryptsetup), NON tocchiamo
    # il sistema di avvio: sostituire l'initramfs con dracut su un sistema dove
    # tutto funziona gia' rischierebbe solo di romperlo. Ci limitiamo a installare
    # l'helper di ri-registrazione e usciamo.
    if systemd-cryptenroll "$luks_dev" 2>/dev/null | grep -qi "tpm2" \
       && { [ -e /usr/lib/systemd/systemd-cryptsetup ] || [ -e /lib/systemd/systemd-cryptsetup ]; } \
       && ! dpkg -l initramfs-tools 2>/dev/null | grep -q '^ii'; then
        log "Cifratura TPM gia' gestita nativamente (Ubuntu 26.04+): non modifico il boot."
        _install_tpm_reenroll_helper "$luks_dev" "$TPM_PCRS"
        return 0
    fi

    # dracut sostituisce il sistema initramfs, tpm2-tools/mokutil servono per
    # leggere lo stato del TPM e del Secure Boot.
    execute "apt install -y dracut dracut-core tpm2-tools libtss2-tcti-device0 cryptsetup mokutil"

    # Leggiamo lo stato del Secure Boot e decidiamo come comportarci.
    # Perche' conta: il PCR 7 (a cui leghiamo la chiave) misura proprio lo stato
    # del Secure Boot. Con Secure Boot attivo la protezione e' reale; se e'
    # disattivato, lo sblocco automatico offre poca sicurezza, quindi di default
    # preferiamo NON procedere per non dare una falsa sensazione di protezione.
    local sb_state
    sb_state=$(mokutil --sb-state 2>/dev/null | head -n1 || echo "sconosciuto")
    log "Stato Secure Boot: ${sb_state}"
    case "$sb_state" in
        *enabled*)
            log "OK: Secure Boot attivo. Il PCR $TPM_PCRS e' significativo."
            ;;
        *disabled*)
            log "Attenzione: Secure Boot DISATTIVATO."
            if [ "$TPM_FORCE_NO_SB" != true ]; then
                log "  Senza Secure Boot lo sblocco TPM protegge poco. Salto."
                log "  Usa -F per forzare, oppure attiva Secure Boot e riprova."
                return 0
            fi
            log "  Opzione -F attiva: procedo comunque (a tuo rischio)."
            ;;
        *)
            log "Attenzione: stato Secure Boot non determinabile."
            if [ "$TPM_FORCE_NO_SB" != true ]; then
                log "  Salto per prudenza. Usa -F per forzare."
                return 0
            fi
            ;;
    esac

    # Se la chiave TPM e' gia' stata registrata in passato, non la rifacciamo:
    # evitiamo doppioni e richieste di passphrase inutili. Aggiorniamo solo l'helper.
    if systemd-cryptenroll "$luks_dev" 2>/dev/null | grep -qi "tpm2"; then
        log "Chiave TPM2 gia' presente su $luks_dev: non serve rifarla."
        _install_tpm_reenroll_helper "$luks_dev" "$TPM_PCRS"
        return 0
    fi

    # Salviamo su file il valore attuale dei PCR come "fotografia dello stato buono".
    # In futuro, se lo sblocco si rompe, basta confrontare per capire se e cosa
    # e' cambiato nello stato di avvio.
    local pcr_ref="/root/tpm2-pcr-reference.txt"
    {
        echo "# Riferimento PCR salvato il $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# Disco LUKS  : $luks_dev"
        echo "# Secure Boot : $sb_state"
        echo "# PCR usati   : $TPM_PCRS"
        echo
        tpm2_pcrread "sha256:$TPM_PCRS" 2>/dev/null || echo "tpm2_pcrread non disponibile"
    } > "$pcr_ref" 2>/dev/null
    execute "chmod 600 $pcr_ref" false
    log "Stato PCR di riferimento salvato in $pcr_ref"

    # Diciamo a dracut di includere il supporto TPM nell'immagine di avvio.
    execute "mkdir -p /etc/dracut.conf.d"
    cat > /etc/dracut.conf.d/tpm2.conf << 'EOF'
add_dracutmodules+=" tpm2-tss crypt "
EOF

    # Backup dell'immagine initramfs attuale: e' la nostra rete di sicurezza
    # prima di sostituire il sistema di avvio.
    local kver
    kver=$(uname -r)
    if [ -f "/boot/initrd.img-${kver}" ]; then
        execute "cp /boot/initrd.img-${kver} /boot/initrd.img-${kver}.initramfs-tools.bak" false
    fi

    # Passaggio piu' "delicato": rimuoviamo il vecchio initramfs-tools (solo se
    # presente) e rigeneriamo l'immagine di avvio con dracut.
    if dpkg -l initramfs-tools 2>/dev/null | grep -q '^ii'; then
        execute "apt remove -y initramfs-tools initramfs-tools-core"
    fi
    execute "dracut --force --regenerate-all"

    # Registriamo la chiave nel TPM. Questo NON cancella la passphrase esistente:
    # lo "slot" della passphrase resta come metodo di recupero. Verra' chiesta
    # la passphrase attuale per autorizzare l'operazione.
    log "Registro la chiave nel TPM (PCR: $TPM_PCRS). Verra' chiesta la passphrase..."
    if ! execute "systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=$TPM_PCRS $luks_dev"; then
        log "Errore: registrazione fallita. Il sistema resta avviabile con la passphrase."
        return 1
    fi

    # Controlli dopo la registrazione: vogliamo trovare sia lo slot TPM2 (lo
    # sblocco automatico) sia quello con la passphrase (il recupero d'emergenza).
    if systemd-cryptenroll "$luks_dev" 2>/dev/null | grep -qi "tpm2"; then
        log "OK: slot TPM2 presente."
    else
        log "Attenzione: slot TPM2 non rilevato dopo la registrazione."
    fi
    if ! systemd-cryptenroll "$luks_dev" 2>/dev/null | grep -qi "password"; then
        log "ATTENZIONE: nessuno slot passphrase di recupero! NON riavviare prima"
        log "            di averne aggiunto uno, rischieresti di non entrare piu'."
    fi

    # Aggiorniamo crypttab (con backup) per dire al sistema di provare il TPM.
    if [ -f /etc/crypttab ] && ! grep -q "tpm2-device=auto" /etc/crypttab; then
        execute "cp /etc/crypttab /etc/crypttab.bak" false
        execute "sed -i 's/\(luks\)\s*\$/\1,tpm2-device=auto/' /etc/crypttab" false
    fi

    # Aggiungiamo i parametri di avvio necessari a grub (con backup).
    if [ -f /etc/default/grub ] && ! grep -q "rd.luks" /etc/default/grub; then
        execute "cp /etc/default/grub /etc/default/grub.bak" false
        execute "sed -i 's/\(GRUB_CMDLINE_LINUX=\"\)/\1rd.auto rd.luks=1 /' /etc/default/grub" false
    fi
    execute "update-grub" false

    _install_tpm_reenroll_helper "$luks_dev" "$TPM_PCRS"

    log "==================================================================="
    log "Sblocco automatico TPM configurato."
    log " - La passphrase LUKS e' ancora valida (metodo di recupero)."
    log " - Se lo sblocco TPM fallisce, il sistema richiede la passphrase."
    log " - Secure Boot: $sb_state | PCR: $TPM_PCRS"
    log " - Dopo update firmware/BIOS o cambio Secure Boot: sudo tpm-reenroll"
    log " - Stato PCR di riferimento: $pcr_ref"
    log " - IMPORTANTE: prova un riavvio controllato (con la console aperta)"
    log "   prima di fare affidamento sullo sblocco automatico."
    log "==================================================================="
}

# Eseguiamo il setup TPM solo se richiesto esplicitamente con -T.
# E' una scelta voluta: e' un'operazione che tocca l'avvio del sistema, quindi
# meglio che parta solo su richiesta e non in automatico su ogni macchina.
if [ "$SETUP_TPM" = true ]; then
    setup_tpm_luks
fi

# -----------------------------------------------------------------------------
# Creazione di un utente a partire dal file YAML
# -----------------------------------------------------------------------------
setup_user() {
    local user_index=$1

    # Lo username e' obbligatorio: senza, non possiamo fare nulla.
    local username=$(yq ".users[$user_index].username" "$USERS_CONFIG" | tr -d '"')
    if [ -z "$username" ] || [ "$username" = "null" ]; then
        log "Errore: lo username e' obbligatorio per l'utente all'indice $user_index"
        return 1
    fi

    # Campi opzionali, con valori di default se non specificati nel file.
    local full_name=$(yq ".users[$user_index].full_name // \"\"" "$USERS_CONFIG" | tr -d '"')
    local uid=$(yq ".users[$user_index].uid // \"\"" "$USERS_CONFIG" | tr -d '"')
    local shell=$(yq ".users[$user_index].shell // \"/bin/bash\"" "$USERS_CONFIG" | tr -d '"')
    local password=$(yq ".users[$user_index].password // \"\"" "$USERS_CONFIG" | tr -d '"')

    log "Dettagli utente:"
    log "  - Username: $username"
    log "  - Nome: ${full_name:-<non impostato>}"
    log "  - UID: ${uid:-<automatico>}"
    log "  - Shell: $shell"
    log "  - Password: $([ -n "$password" ] && echo "<impostata>" || echo "<non impostata>")"

    if [ "$NON_INTERACTIVE" = false ]; then
        read -p "Procedo con questo utente? (Y/n) " confirm
        if [[ "$confirm" =~ ^[Nn]$ ]]; then
            log "Utente saltato su richiesta"
            return 0
        fi
    fi

    # Se l'utente esiste gia' aggiorniamo i suoi dati; altrimenti lo creiamo.
    # getent e' il modo affidabile per controllare l'esistenza di un account.
    local is_new_user=true
    if getent passwd "$username" >/dev/null 2>&1; then
        is_new_user=false
        log "L'utente $username esiste gia', aggiorno la configurazione..."

        if [ -n "$full_name" ] && [ "$full_name" != "null" ]; then
            execute "chfn -f \"$full_name\" $username" false
        fi

        local current_shell=$(getent passwd "$username" | cut -d: -f7)
        if [ -n "$shell" ] && [ "$shell" != "null" ] && [ "$current_shell" != "$shell" ]; then
            log "Cambio shell da $current_shell a $shell"
            execute "chsh -s \"$shell\" $username" false
        fi
    else
        log "Creo il nuovo utente: $username"
        local uid_opt=""
        [ -n "$uid" ] && [ "$uid" != "null" ] && uid_opt="-u $uid"
        local comment_opt=""
        [ -n "$full_name" ] && [ "$full_name" != "null" ] && comment_opt="-c \"$full_name\""

        if ! execute "useradd -m -s \"$shell\" $uid_opt $comment_opt \"$username\""; then
            log "Errore: creazione dell'utente $username fallita"
            return 1
        fi
    fi

    # Aggiunta ai gruppi indicati (vale sia per utenti nuovi che esistenti).
    local groups
    groups=$(yq ".users[$user_index].groups[]" "$USERS_CONFIG" 2>/dev/null | tr -d '"')
    if [ $? -eq 0 ] && [ -n "$groups" ] && [ "$groups" != "null" ]; then
        for group in $groups; do
            execute "usermod -aG \"$group\" \"$username\"" false
        done
    fi

    # Password: solo per i nuovi utenti.
    if [ "$is_new_user" = true ]; then
        if [ -n "$password" ]; then
            log "Imposto la password per $username..."
            echo "$username:$password" | chpasswd
        else
            if [ "$NON_INTERACTIVE" = true ]; then
                # Senza password e senza poter chiedere nulla, ne generiamo una a
                # caso ma NON la stampiamo nei log (finirebbe scritta su disco);
                # la marchiamo come "scaduta" cosi' l'utente deve cambiarla al
                # primo accesso.
                log "Nessuna password indicata per $username: ne genero una casuale."
                local random_pass
                random_pass=$(openssl rand -base64 24)
                echo "$username:$random_pass" | chpasswd
                execute "passwd -e $username" false
                log "Password casuale impostata e scaduta: va cambiata al primo accesso."
            else
                passwd "$username"
            fi
        fi
    fi

    # Configurazione di zsh: cloniamo il repo dei dotfile e lanciamo il setup.
    # Se qualcosa va storto non blocchiamo tutto: lasciamo l'utente comunque
    # utilizzabile (al limite con la shell di default).
    log "Configuro zsh per l'utente $username..."
    if ! execute "su - $username -c 'git clone https://github.com/steccas/steccaScripts.git'" false; then
        log "Avviso: clone del repo steccaScripts fallito per $username"
    else
        if ! execute "su - $username -c './steccaScripts/zshsetup.sh -f ./steccaScripts/zsh_plugin_lists/proxmox'" false; then
            log "Avviso: setup zsh fallito per $username, torno alla shell bash"
            execute "chsh -s /bin/bash $username" false
        fi
    fi

    # Chiavi SSH: prepariamo la cartella .ssh con i permessi corretti, poi
    # importiamo le chiavi da GitHub (se indicato) oppure quelle scritte nel file.
    if [ -d "/home/$username" ]; then
        mkdir -p "/home/$username/.ssh"
        chmod 700 "/home/$username/.ssh"
        chown "$username:$username" "/home/$username/.ssh"

        local github_user
        github_user=$(yq ".users[$user_index].ssh.github_username // \"\"" "$USERS_CONFIG" 2>/dev/null | tr -d '"')
        if [ $? -eq 0 ] && [ -n "$github_user" ] && [ "$github_user" != "null" ]; then
            log "Importo le chiavi SSH da GitHub per $github_user"
            if ! execute "su - $username -c \"ssh-import-id gh:$github_user\"" false; then
                log "Avviso: import delle chiavi GitHub fallito per $github_user"
            fi
        else
            local keys
            keys=$(yq ".users[$user_index].ssh.authorized_keys[]" "$USERS_CONFIG" 2>/dev/null | tr -d '"')
            if [ $? -eq 0 ] && [ -n "$keys" ] && [ "$keys" != "null" ]; then
                echo "$keys" > "/home/$username/.ssh/authorized_keys"
                chmod 600 "/home/$username/.ssh/authorized_keys"
                chown -R "$username:$username" "/home/$username/.ssh"
            fi
        fi
    fi
}

# Creazione di tutti gli utenti elencati nel file YAML.
if [ -n "$USERS_CONFIG" ]; then
    log "Configuro gli utenti dal file $USERS_CONFIG..."

    if [ ! -f "$USERS_CONFIG" ]; then
        handle_error "File di configurazione utenti non trovato: $USERS_CONFIG"
    fi

    # Controllo minimo che il file abbia la struttura attesa (un array .users).
    if ! yq '.users' "$USERS_CONFIG" >/dev/null 2>&1; then
        handle_error "Struttura YAML non valida: array .users non trovato"
    fi

    user_count=$(yq '.users | length' "$USERS_CONFIG")
    if [ $? -ne 0 ] || [ -z "$user_count" ] || [ "$user_count" = "null" ]; then
        handle_error "Impossibile leggere il numero di utenti dal file"
    fi

    if [ "$user_count" -eq 0 ]; then
        log "Avviso: nessun utente definito nel file di configurazione"
    else
        for i in $(seq 0 $((user_count - 1))); do
            if ! setup_user $i; then
                handle_error "Configurazione dell'utente all'indice $i fallita"
            fi
        done
    fi
fi

# -----------------------------------------------------------------------------
# Installazione di Docker (dal repository ufficiale)
# -----------------------------------------------------------------------------
if [ "$SKIP_DOCKER" = false ]; then
    log "Installo Docker..."

    # Aggiungiamo la chiave GPG e il repository ufficiale di Docker.
    execute "apt install -y ca-certificates curl"
    execute "install -m 0755 -d /etc/apt/keyrings"
    execute "curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc"
    execute "chmod a+r /etc/apt/keyrings/docker.asc"

    # Usiamo il nuovo formato .sources (deb822): su Ubuntu 26.04 il vecchio
    # formato .list e' ancora accettato ma e' deprecato, quindi adottiamo subito
    # quello consigliato. Il codename (noble/resolute/...) viene letto da solo,
    # cosi' lo stesso comando funziona su tutte le versioni di Ubuntu.
    local_codename=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
    cat > /etc/apt/sources.list.d/docker.sources << EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${local_codename}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    # Installiamo Docker con i plugin moderni: Buildx (build avanzate) e
    # Compose v2 (il comando 'docker compose').
    execute "apt update"
    execute "apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"

    log "Configuro la rete per Docker..."
    # Impostazioni del demone Docker. L'inoltro IP (ip_forward) lo gestiamo una
    # sola volta, piu' avanti, nel file di ottimizzazione di rete.
    execute "mkdir -p /etc/docker"
    cat > /etc/docker/daemon.json << 'EOF'
{
  "iptables": true,
  "live-restore": true,
  "userland-proxy": false
}
EOF

    # Permettiamo a Docker di inoltrare il traffico dei container attraverso UFW.
    if [ "$SKIP_UFW" = false ]; then
        log "Configuro UFW per la rete di Docker..."
        execute "sed -i '/DEFAULT_FORWARD_POLICY=/c\DEFAULT_FORWARD_POLICY=\"ACCEPT\"' /etc/default/ufw"
        execute "ufw reload"
    fi

    execute "systemctl enable docker"
    execute "systemctl start docker"

    # Aggiungiamo gli utenti al gruppo docker, cosi' possono usarlo senza sudo.
    if [ -n "$USERS_CONFIG" ]; then
        user_count=$(yq '.users | length' "$USERS_CONFIG")
        for i in $(seq 0 $((user_count - 1))); do
            username=$(yq ".users[$i].username" "$USERS_CONFIG" | tr -d '"')
            if [ -n "$username" ]; then
                log "Aggiungo $username al gruppo docker..."
                execute "usermod -aG docker $username"
            fi
        done
    fi
fi

# -----------------------------------------------------------------------------
# Ottimizzazioni di rete e protezioni di base del kernel
# -----------------------------------------------------------------------------
if [ "$SKIP_DOCKER" = false ]; then
    log "Applico inoltro IP e ottimizzazioni di rete..."

    # Questi parametri migliorano la gestione delle connessioni e aggiungono
    # alcune protezioni standard (es. contro gli attacchi SYN flood).
    execute "cat > /etc/sysctl.d/99-network-tune.conf << 'EOF'
# Inoltro IP, necessario a Docker
net.ipv4.ip_forward=1

# Allarga l'intervallo di porte disponibili
net.ipv4.ip_local_port_range=1024 65535

# Buffer TCP piu' ampi
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216

# TCP Fast Open
net.ipv4.tcp_fastopen=3

# Code di rete piu' capienti
net.core.netdev_max_backlog=16384
net.core.somaxconn=8192

# Riutilizzo piu' rapido delle connessioni chiuse
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15

# Disattiva IPv6 (se non serve)
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1

# Protezioni TCP
net.ipv4.tcp_rfc1337=1
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_max_syn_backlog=8192
EOF"

    # Applichiamo subito le impostazioni appena scritte.
    execute "sysctl -p /etc/sysctl.d/99-network-tune.conf"
fi

# Setup zsh "locale", utile solo se lo script viene lanciato da dentro il repo
# che contiene zshsetup.sh. Se i file non ci sono, semplicemente si salta.
if [ -x "./zshsetup.sh" ]; then
    local_plugins_file="./zsh_plugin_lists/proxmox"
    if [ -f "$local_plugins_file" ]; then
        execute "./zshsetup.sh -f $local_plugins_file" false
    else
        log "Salto il setup zsh locale: ./zsh_plugin_lists/proxmox non presente."
    fi
else
    log "Salto il setup zsh locale: ./zshsetup.sh non presente o non eseguibile."
fi

# Riepilogo finale con i controlli consigliati.
log "Configurazione del server completata!"
log "Cose da verificare:"
log "1. Che tutti i servizi siano attivi"
log "2. Le regole del firewall UFW"
log "3. L'accesso e i permessi sudo degli utenti"
[ "$SKIP_DOCKER" = false ] && log "4. Docker con: docker run hello-world"
[ "$SETUP_TPM" = true ] && log "5. Riavvio controllato per verificare lo sblocco automatico del disco"

exit 0
