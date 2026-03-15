#!/bin/bash

# ============================================================
#  Gerobug DKIM Setup Script
#  Sets up OpenDKIM + Postfix sidecar for DKIM signing
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

print_banner() {
    echo -e "${CYAN}"
    echo "  ██████  ███████ ██████   ██████  ██████  ██    ██  ██████  "
    echo " ██       ██      ██   ██ ██    ██ ██   ██ ██    ██ ██       "
    echo " ██   ███ █████   ██████  ██    ██ ██████  ██    ██ ██   ███ "
    echo " ██    ██ ██      ██   ██ ██    ██ ██   ██ ██    ██ ██    ██ "
    echo "  ██████  ███████ ██   ██  ██████  ██████   ██████   ██████  "
    echo -e "${NC}"
    echo -e "${BOLD}  Gerobug DKIM + Postfix  Relay Setup${NC}"
    echo "  ============================================"
    echo ""
}

print_step() {
    echo -e "\n${CYAN}${BOLD}[$1]${NC} $2"
}

print_success() {
    echo -e "${GREEN}✔ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✘ $1${NC}"
}

ask() {
    local prompt="$1"
    local var="$2"
    local default="$3"
    local secret="$4"

    if [ -n "$default" ]; then
        prompt="$prompt [${default}]"
    fi

    echo -ne "${BOLD}  → $prompt: ${NC}"

    if [ "$secret" = "true" ]; then
        read -s value
        echo ""
    else
        read value
    fi

    if [ -z "$value" ] && [ -n "$default" ]; then
        value="$default"
    fi

    eval "$var='$value'"
}

confirm() {
    echo -ne "\n${YELLOW}${BOLD}  → $1 [y/N]: ${NC}"
    read answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

check_requirements() {
    print_step "0" "Checking requirements..."

    local missing=0

    if ! command -v docker &>/dev/null; then
        print_error "Docker is not installed"
        missing=1
    else
        print_success "Docker found"
    fi

    if ! docker compose version &>/dev/null; then
        print_error "Docker Compose v2 is not installed"
        missing=1
    else
        print_success "Docker Compose found"
    fi

    if [ $missing -eq 1 ]; then
        echo -e "\n${RED}Please install missing requirements and re-run setup.${NC}"
        exit 1
    fi
}

collect_info() {
    print_step "1" "Collecting configuration..."
    echo ""

    echo -e "${BOLD}  -- Gerobug Network --${NC}"
    ask "Gerobug Docker network name" GEROBUG_NETWORK "gerobug_default"

    # Validate network exists
    if ! docker network inspect "$GEROBUG_NETWORK" &>/dev/null; then
        print_warning "Network '$GEROBUG_NETWORK' not found."
        echo -e "  Available networks:"
        docker network ls --format "    {{.Name}}" | grep -v "^bridge$\|^host$\|^none$"
        ask "Enter the correct network name" GEROBUG_NETWORK ""
        if ! docker network inspect "$GEROBUG_NETWORK" &>/dev/null; then
            print_error "Network '$GEROBUG_NETWORK' still not found. Exiting."
            exit 1
        fi
    fi
    print_success "Network '$GEROBUG_NETWORK' found"

    echo ""
    echo -e "${BOLD}  -- SMTP Relay --${NC}"
    ask "SMTP relay server" SMTP_SERVER "smtp.server.com"
    ask "SMTP relay port" SMTP_PORT "465"
    ask "SMTP username (email)" SMTP_USERNAME "your-email@gerosecurity.com"
    ask "SMTP password" SMTP_PASSWORD "" "true"

    echo ""
    echo -e "${BOLD}  -- DKIM Configuration --${NC}"
    # Extract domain from SMTP username
    DEFAULT_DOMAIN="${SMTP_USERNAME#*@}"
    ask "Signing domain" DKIM_DOMAIN "$DEFAULT_DOMAIN"
    ask "DKIM selector" DKIM_SELECTOR "gerobug"
}

escape_password() {
    # Escape $ signs for docker-compose yaml
    echo "${1//\$/\$\$}"
}

generate_dkim_keys() {
    print_step "2" "Generating DKIM keypair..."

    local KEY_DIR="$SCRIPT_DIR/keys/$DKIM_DOMAIN"
    mkdir -p "$KEY_DIR"

    # Check if key already exists
    if [ -f "$KEY_DIR/$DKIM_SELECTOR.private" ]; then
        print_warning "Key already exists at $KEY_DIR/$DKIM_SELECTOR.private"
        if ! confirm "Regenerate key? (This will require updating your DNS record)"; then
            print_success "Using existing key"
            return
        fi
    fi

    docker run --rm \
        -v "$KEY_DIR:/output" \
        instrumentisto/opendkim \
        opendkim-genkey -b 2048 -d "$DKIM_DOMAIN" -D /output -s "$DKIM_SELECTOR" -v

    if [ $? -ne 0 ]; then
        print_error "Failed to generate DKIM keys"
        exit 1
    fi

    # Fix permissions - opendkim runs as root inside container
    sudo chown -R root:root "$KEY_DIR"
    sudo chmod 700 "$KEY_DIR"
    sudo chmod 600 "$KEY_DIR/$DKIM_SELECTOR.private"

    print_success "DKIM keys generated at $KEY_DIR"
}

write_config_files() {
    print_step "3" "Writing configuration files..."

    # opendkim.conf
    cat > "$SCRIPT_DIR/opendkim.conf" <<EOF
Mode                    sv
Canonicalization        relaxed/relaxed
Socket                  inet:8891@0.0.0.0
Syslog                  yes
LogWhy                  yes
KeyTable                /etc/opendkim/KeyTable
SigningTable            refile:/etc/opendkim/SigningTable
ExternalIgnoreList      /etc/opendkim/TrustedHosts
InternalHosts           /etc/opendkim/TrustedHosts
EOF
    print_success "opendkim.conf written"

    # KeyTable
    cat > "$SCRIPT_DIR/KeyTable" <<EOF
${DKIM_SELECTOR}._domainkey.${DKIM_DOMAIN} ${DKIM_DOMAIN}:${DKIM_SELECTOR}:/etc/opendkim/keys/${DKIM_DOMAIN}/${DKIM_SELECTOR}.private
EOF
    print_success "KeyTable written"

    # SigningTable
    cat > "$SCRIPT_DIR/SigningTable" <<EOF
*@${DKIM_DOMAIN} ${DKIM_SELECTOR}._domainkey.${DKIM_DOMAIN}
EOF
    print_success "SigningTable written"

    # TrustedHosts - detect subnet from network
    local SUBNET
    SUBNET=$(docker network inspect "$GEROBUG_NETWORK" \
        --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null)

    if [ -z "$SUBNET" ]; then
        SUBNET="172.16.0.0/12"
        print_warning "Could not detect subnet, defaulting to $SUBNET"
    else
        print_success "Detected network subnet: $SUBNET"
    fi

    cat > "$SCRIPT_DIR/TrustedHosts" <<EOF
127.0.0.1
localhost
${SUBNET}
postfix
EOF
    print_success "TrustedHosts written"
}

write_compose_file() {
    print_step "4" "Writing docker-compose.yml..."

    local ESCAPED_PWD
    ESCAPED_PWD=$(escape_password "$SMTP_PASSWORD")

    # Determine TLS wrapper mode based on port
    local TLS_WRAPPERMODE="no"
    if [ "$SMTP_PORT" = "465" ]; then
        TLS_WRAPPERMODE="yes"
    fi

    cat > "$SCRIPT_DIR/docker-compose.yml" <<EOF
services:
  opendkim:
    image: instrumentisto/opendkim
    volumes:
      - ./keys:/etc/opendkim/keys
      - ./opendkim.conf:/etc/opendkim/opendkim.conf
      - ./KeyTable:/etc/opendkim/KeyTable
      - ./SigningTable:/etc/opendkim/SigningTable
      - ./TrustedHosts:/etc/opendkim/TrustedHosts
    expose:
      - 8891
    restart: unless-stopped
    networks:
      - gerobug_network

  postfix:
    image: boky/postfix
    environment:
      RELAYHOST: "[${SMTP_SERVER}]:${SMTP_PORT}"
      RELAYHOST_USERNAME: "${SMTP_USERNAME}"
      RELAYHOST_PASSWORD: "${ESCAPED_PWD}"
      ALLOWED_SENDER_DOMAINS: "${DKIM_DOMAIN}"
      MYNETWORKS: "127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
      POSTFIX_smtp_tls_security_level: "encrypt"
      POSTFIX_smtp_tls_wrappermode: "${TLS_WRAPPERMODE}"
      POSTFIX_milter_default_action: "accept"
      POSTFIX_smtpd_milters: "inet:opendkim:8891"
      POSTFIX_non_smtpd_milters: "inet:opendkim:8891"
    expose:
      - 25
    depends_on:
      - opendkim
    restart: unless-stopped
    networks:
      - gerobug_network

networks:
  gerobug_network:
    external: true
    name: ${GEROBUG_NETWORK}
EOF
    print_success "docker-compose.yml written"
}

show_dns_instructions() {
    print_step "5" "DNS Setup Instructions"

    local KEY_DIR="$SCRIPT_DIR/keys/$DKIM_DOMAIN"
    local DNS_VALUE

    echo ""
    echo -e "${BOLD}  Add the following TXT record to your DNS (Cloudflare):${NC}"
    echo ""
    echo -e "  ${YELLOW}Type:${NC}    TXT"
    echo -e "  ${YELLOW}Name:${NC}    ${DKIM_SELECTOR}._domainkey"
    echo -e "  ${YELLOW}Content:${NC}"
    echo ""

    # Extract just the p= value for clean display
    if [ -f "$KEY_DIR/$DKIM_SELECTOR.txt" ]; then
        DNS_VALUE=$(cat "$KEY_DIR/$DKIM_SELECTOR.txt" | grep -o 'p=.*"' | tr -d '"' | tr -d ' ' | tr -d '\n')
        echo -e "  v=DKIM1; k=rsa; ${DNS_VALUE}"
        echo ""
        echo -e "  ${CYAN}Full record (paste as-is if provider needs it):${NC}"
        cat "$KEY_DIR/$DKIM_SELECTOR.txt"
    fi

    echo ""
    echo -e "  ${YELLOW}Verify propagation with:${NC}"
    echo "  dig TXT ${DKIM_SELECTOR}._domainkey.${DKIM_DOMAIN} +short"
}

start_stack() {
    print_step "6" "Starting DKIM stack..."

    if confirm "Start the stack now?"; then
        docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d

        if [ $? -eq 0 ]; then
            print_success "Stack started successfully"
            echo ""
            docker compose -f "$SCRIPT_DIR/docker-compose.yml" ps
        else
            print_error "Failed to start stack"
            exit 1
        fi
    else
        echo ""
        print_warning "Stack not started. Run manually with:"
        echo "  docker compose -f $SCRIPT_DIR/docker-compose.yml up -d"
    fi
}

show_db_instructions() {
    print_step "7" "Update Gerobug Mailbox Settings"

    echo ""
    echo -e "  ${BOLD}Run the following to point Gerobug to the Postfix relay:${NC}"
    echo ""
    echo -e "  ${YELLOW}Find your DB container:${NC}"
    echo "  docker ps | grep postgres"
    echo ""
    echo -e "  ${YELLOW}Update mailbox settings:${NC}"
    echo "  docker exec -it <db-container> psql -U gerobug -d gerobug_db -c \\"
    echo "  \"UPDATE prerequisites_mailbox SET mailbox_smtp='postfix', mailbox_smtp_port=25 WHERE mailbox_id=1;\""
    echo ""
    echo -e "  ${BOLD}Note:${NC} Keep your IMAP password unchanged — only SMTP server and port change."
}

show_startup_instructions() {
    print_step "8" "Startup Order on Reboot"

    echo ""
    echo -e "  ${BOLD}Ensure DKIM stack starts before Gerobug on reboot.${NC}"
    echo "  Add to /etc/rc.local before your gerobug.sh line:"
    echo ""
    echo "  cd $SCRIPT_DIR && docker compose up -d"
    echo "  sleep 5"
}

# ============================================================
#  MAIN
# ============================================================

print_banner
check_requirements
collect_info
generate_dkim_keys
write_config_files
write_compose_file
show_dns_instructions
start_stack
show_db_instructions
show_startup_instructions

echo ""
echo -e "${GREEN}${BOLD}  ✔ Setup complete!${NC}"
echo ""
echo -e "  Monitor logs with:"
echo "  docker compose -f $SCRIPT_DIR/docker-compose.yml logs -f"
echo ""