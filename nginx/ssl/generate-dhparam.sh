#!/bin/bash
# nginx/ssl/generate-dhparam.sh
# Generate strong Diffie-Hellman parameters for SSL

set -e

echo "🔐 Generating Diffie-Hellman parameters..."
echo "This may take several minutes on weaker hardware..."

# Create directories
mkdir -p dhparams
mkdir -p /etc/nginx/ssl

# Generate 4096-bit DH parameters
if ! openssl dhparam -out dhparams/dhparam.pem 4096; then
    echo "❌ Failed to generate DH parameters"
    exit 1
fi

# Generate 2048-bit fallback (faster)
if ! openssl dhparam -out dhparams/dhparam-2048.pem 2048; then
    echo "⚠️  Failed to generate 2048-bit DH parameters"
fi

# Copy to Nginx directory
sudo cp dhparams/dhparam.pem /etc/nginx/ssl/dhparam.pem
sudo chmod 600 /etc/nginx/ssl/dhparam.pem

echo "✅ DH parameters generated and installed"
echo "📍 Location: /etc/nginx/ssl/dhparam.pem"
