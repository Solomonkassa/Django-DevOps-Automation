#!/bin/bash
# nginx/ssl/generate-selfsigned.sh
# Generate self-signed SSL certificates for development

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

DOMAIN="${1:-localhost}"
VALID_DAYS="${2:-365}"
CERT_DIR="certs/${DOMAIN}"

echo -e "${YELLOW}🔐 Generating self-signed SSL certificate for: ${DOMAIN}${NC}"

# Create certificate directory
mkdir -p "${CERT_DIR}"

# Generate private key
echo -e "${YELLOW}Generating private key...${NC}"
openssl genrsa -out "${CERT_DIR}/privkey.pem" 4096

# Generate CSR
echo -e "${YELLOW}Generating Certificate Signing Request...${NC}"
openssl req -new -key "${CERT_DIR}/privkey.pem" \
    -out "${CERT_DIR}/csr.pem" \
    -subj "/C=US/ST=State/L=City/O=Organization/CN=${DOMAIN}"

# Create config file for SAN
cat > "${CERT_DIR}/openssl.cnf" << EOF
[req]
default_bits = 4096
prompt = no
default_md = sha256
req_extensions = req_ext
distinguished_name = dn

[dn]
C = US
ST = State
L = City
O = Organization
CN = ${DOMAIN}

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${DOMAIN}
DNS.2 = *.${DOMAIN}
DNS.3 = localhost
IP.1 = 127.0.0.1
EOF

# Generate self-signed certificate
echo -e "${YELLOW}Generating self-signed certificate...${NC}"
openssl x509 -req -days "${VALID_DAYS}" \
    -in "${CERT_DIR}/csr.pem" \
    -signkey "${CERT_DIR}/privkey.pem" \
    -out "${CERT_DIR}/cert.pem" \
    -extfile "${CERT_DIR}/openssl.cnf" \
    -extensions req_ext

# Create fullchain (same as cert for self-signed)
cp "${CERT_DIR}/cert.pem" "${CERT_DIR}/fullchain.pem"

# Create chain file
cat > "${CERT_DIR}/chain.pem" << EOF
Self-signed certificate for ${DOMAIN}
Valid for ${VALID_DAYS} days
Generated: $(date)
EOF

# Set permissions
chmod 600 "${CERT_DIR}/privkey.pem"
chmod 644 "${CERT_DIR}/"*.pem

echo -e "${GREEN}✅ Self-signed SSL certificate generated!${NC}"
echo -e "${GREEN}📍 Certificate files:${NC}"
echo -e "  Private Key: ${CERT_DIR}/privkey.pem"
echo -e "  Certificate: ${CERT_DIR}/cert.pem"
echo -e "  Full Chain:  ${CERT_DIR}/fullchain.pem"
echo -e "\n${YELLOW}⚠️  Warning: Self-signed certificates are for development only!${NC}"
